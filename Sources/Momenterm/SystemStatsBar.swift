import AppKit
import Darwin
import Foundation

// Samples system-wide CPU / memory / network usage using mach + BSD APIs. Rates are computed
// from deltas between successive calls, so `sample()` must be invoked on a steady cadence.
final class SystemStatsSampler {
    struct Sample {
        let cpuPercent: Double        // 0...100 across all cores
        let memUsedBytes: UInt64
        let memTotalBytes: UInt64
        let rxBytesPerSec: Double
        let txBytesPerSec: Double
    }

    private var previousCPU: host_cpu_load_info?
    private var previousNet: (rx: UInt64, tx: UInt64, time: TimeInterval)?

    func sample(now: TimeInterval) -> Sample {
        let cpu = sampleCPU()
        let mem = sampleMemory()
        let net = sampleNetwork(now: now)
        return Sample(
            cpuPercent: cpu,
            memUsedBytes: mem.used,
            memTotalBytes: mem.total,
            rxBytesPerSec: net.rx,
            txBytesPerSec: net.tx
        )
    }

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return 0
        }
        defer { previousCPU = info }
        guard let previous = previousCPU else {
            return 0
        }
        let userDelta = Double(info.cpu_ticks.0 &- previous.cpu_ticks.0)
        let systemDelta = Double(info.cpu_ticks.1 &- previous.cpu_ticks.1)
        let idleDelta = Double(info.cpu_ticks.2 &- previous.cpu_ticks.2)
        let niceDelta = Double(info.cpu_ticks.3 &- previous.cpu_ticks.3)
        let busy = userDelta + systemDelta + niceDelta
        let total = busy + idleDelta
        guard total > 0 else {
            return 0
        }
        return min(max(busy / total * 100.0, 0), 100)
    }

    private func sampleMemory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (0, total)
        }
        let pageSize = UInt64(vm_page_size)
        // "App-ish" footprint: active + wired + compressed pages, matching how Activity Monitor
        // reports memory pressure rather than counting cached/free pages as used.
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        let used = (active + wired + compressed) * pageSize
        return (min(used, total), total)
    }

    private func sampleNetwork(now: TimeInterval) -> (rx: Double, tx: Double) {
        var rxTotal: UInt64 = 0
        var txTotal: UInt64 = 0
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return (0, 0)
        }
        defer { freeifaddrs(addressList) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: interface.ifa_name)
                // Skip loopback so the numbers reflect real traffic.
                if !name.hasPrefix("lo"), let dataPointer = interface.ifa_data {
                    let data = dataPointer.assumingMemoryBound(to: if_data.self).pointee
                    rxTotal += UInt64(data.ifi_ibytes)
                    txTotal += UInt64(data.ifi_obytes)
                }
            }
            pointer = interface.ifa_next
        }
        defer { previousNet = (rxTotal, txTotal, now) }
        guard let previous = previousNet else {
            return (0, 0)
        }
        let elapsed = now - previous.time
        guard elapsed > 0.01 else {
            return (0, 0)
        }
        let rxRate = Double(rxTotal &- previous.rx) / elapsed
        let txRate = Double(txTotal &- previous.tx) / elapsed
        return (max(rxRate, 0), max(txRate, 0))
    }
}

// A single window-wide status bar pinned to the bottom, independent of pane splits. Shows
// live CPU / Memory / Network usage, refreshed on its own timer.
final class SystemStatsBarView: NSView {
    private let sampler = SystemStatsSampler()
    private let cpuLabel = SystemStatsBarView.makeValueLabel()
    private let memLabel = SystemStatsBarView.makeValueLabel()
    private let netLabel = SystemStatsBarView.makeValueLabel()
    private let stack = NSStackView()
    private var timer: Timer?
    // mach/BSD syscalls (host_statistics, getifaddrs) run here so they never block the main
    // thread — keeping them off the main run loop avoids interfering with terminal IME input.
    private let samplingQueue = DispatchQueue(label: "momenterm.systemstats.sampling")

    private var labelColor: NSColor = .secondaryLabelColor
    private var positiveColor: NSColor = .systemGreen
    private var attentionColor: NSColor = .systemYellow
    private var dangerColor: NSColor = .systemRed
    private var startTime: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private static func makeValueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byClipping
        label.cell?.usesSingleLineMode = true
        return label
    }

    private func configure() {
        wantsLayer = true
        if layer == nil {
            layer = CALayer()
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 18
        stack.addArrangedSubview(cpuLabel)
        stack.addArrangedSubview(memLabel)
        stack.addArrangedSubview(netLabel)
        addSubview(stack)
        // Fixed widths so the 1.5s value updates never change intrinsic size / trigger a window
        // relayout (which read as flicker). Values are left-aligned within these columns.
        cpuLabel.alignment = .left
        memLabel.alignment = .left
        netLabel.alignment = .left
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            cpuLabel.widthAnchor.constraint(equalToConstant: 78),
            memLabel.widthAnchor.constraint(equalToConstant: 168),
            netLabel.widthAnchor.constraint(equalToConstant: 210)
        ])
        renderPlaceholders()
    }

    func applyColors(background: NSColor, label: NSColor, positive: NSColor, attention: NSColor, danger: NSColor, separator: NSColor) {
        labelColor = label
        positiveColor = positive
        attentionColor = attention
        dangerColor = danger
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = separator.cgColor
        layer?.borderWidth = 1
        renderPlaceholders()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startTimer()
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        stopTimer()
        startTime = ProcessInfo.processInfo.systemUptime
        // Prime the deltas off the main thread, then refresh on a steady cadence.
        samplingQueue.async { [weak self] in
            _ = self?.sampler.sample(now: ProcessInfo.processInfo.systemUptime)
        }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func renderPlaceholders() {
        if cpuLabel.attributedStringValue.length == 0 {
            cpuLabel.attributedStringValue = segment(title: "CPU", value: "--", color: labelColor)
            memLabel.attributedStringValue = segment(title: "MEM", value: "--", color: labelColor)
            netLabel.attributedStringValue = segment(title: "NET", value: "↓ -- ↑ --", color: labelColor)
        }
    }

    private func refresh() {
        // Sample off the main thread; the sampler is only ever touched on this serial queue.
        samplingQueue.async { [weak self] in
            guard let self = self else { return }
            let sample = self.sampler.sample(now: ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.async { [weak self] in
                self?.applySample(sample)
            }
        }
    }

    private func applySample(_ sample: SystemStatsSampler.Sample) {
        let cpuColor: NSColor
        switch sample.cpuPercent {
        case ..<50: cpuColor = positiveColor
        case ..<80: cpuColor = attentionColor
        default: cpuColor = dangerColor
        }
        cpuLabel.attributedStringValue = segment(title: "CPU", value: String(format: "%.0f%%", sample.cpuPercent), color: cpuColor)

        let memPercent = sample.memTotalBytes > 0 ? Double(sample.memUsedBytes) / Double(sample.memTotalBytes) * 100 : 0
        let memColor: NSColor
        switch memPercent {
        case ..<70: memColor = positiveColor
        case ..<88: memColor = attentionColor
        default: memColor = dangerColor
        }
        let memValue = "\(Self.formatBytes(sample.memUsedBytes)) / \(Self.formatBytes(sample.memTotalBytes))"
        memLabel.attributedStringValue = segment(title: "MEM", value: memValue, color: memColor)

        let netValue = "↓ \(Self.formatRate(sample.rxBytesPerSec))  ↑ \(Self.formatRate(sample.txBytesPerSec))"
        netLabel.attributedStringValue = segment(title: "NET", value: netValue, color: labelColor)
    }

    private func segment(title: String, value: String, color: NSColor) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let result = NSMutableAttributedString(
            string: "\(title) ",
            attributes: [.font: boldFont, .foregroundColor: labelColor]
        )
        result.append(NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: color]))
        return result
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    private static func formatRate(_ bytesPerSec: Double) -> String {
        if bytesPerSec >= 1_048_576 {
            return String(format: "%.1f MB/s", bytesPerSec / 1_048_576.0)
        }
        if bytesPerSec >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSec / 1024.0)
        }
        return String(format: "%.0f B/s", bytesPerSec)
    }
}
