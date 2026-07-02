import AppKit

#if MOMENTERM_LIBGHOSTTY
import Metal
import QuartzCore
import libghostty

private final class MomentermGhosttyWeakView {
    weak var view: LibGhosttyTerminalView?

    init(_ view: LibGhosttyTerminalView) {
        self.view = view
    }
}

private final class MomentermGhosttyRuntime {
    static let shared = MomentermGhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var configURL: URL?
    private var views: [MomentermGhosttyWeakView] = []

    private init() {
        ghostty_init(0, nil)

        guard let config = ghostty_config_new() else {
            return
        }
        self.config = config

        // Monaco has no Hangul glyphs, so Korean text renders as tofu (□) unless we
        // supply a fallback chain. Ghostty treats repeated font-family entries as an
        // ordered fallback list: glyphs missing from Monaco resolve against the
        // Korean-capable fonts below (all ship with macOS by default).
        let contents = """
        font-family = Monaco
        font-family = Apple SD Gothic Neo
        font-family = AppleGothic
        font-size = 13
        font-thicken = true
        scrollback-limit = 1048576
        background = 222831
        foreground = eeeeee
        selection-background = 4d4a2f
        cursor-style = block
        cursor-style-blink = true
        window-padding-x = 4
        window-padding-y = 3
        background-opacity = 1
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momenterm-ghostty-\(UUID().uuidString)")
            .appendingPathExtension("conf")
        if (try? contents.write(to: url, atomically: true, encoding: .utf8)) != nil {
            configURL = url
            ghostty_config_load_file(config, url.path)
        }
        ghostty_config_finalize(config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = momentermGhosttyWakeupCallback
        runtime.action_cb = momentermGhosttyActionCallback
        runtime.close_surface_cb = momentermGhosttyCloseSurfaceCallback

        app = ghostty_app_new(&runtime, config)
        if let app = app {
            ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)
        }
    }

    func register(_ view: LibGhosttyTerminalView) {
        views.removeAll { $0.view == nil || $0.view === view }
        views.append(MomentermGhosttyWeakView(view))
    }

    func unregister(_ view: LibGhosttyTerminalView) {
        views.removeAll { $0.view == nil || $0.view === view }
    }

    func requestWakeup() {
        DispatchQueue.main.async { [weak self] in
            self?.views.removeAll { $0.view == nil }
            self?.views.forEach { $0.view?.requestRender() }
        }
    }

    func tick() {
        guard let app = app else {
            return
        }
        ghostty_app_tick(app)
    }

    deinit {
        if let app = app {
            ghostty_app_free(app)
        }
        if let config = config {
            ghostty_config_free(config)
        }
        if let configURL = configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
    }
}

private final class MomentermGhosttyHostBridge {
    weak var owner: LibGhosttyTerminalView?

    init(owner: LibGhosttyTerminalView) {
        self.owner = owner
    }
}

private let momentermGhosttyWakeupCallback: ghostty_runtime_wakeup_cb = { userdata in
    guard let userdata = userdata else {
        return
    }
    let runtime = Unmanaged<MomentermGhosttyRuntime>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    runtime.requestWakeup()
}

private let momentermGhosttyActionCallback: ghostty_runtime_action_cb = { _, _, _ in
    false
}

private let momentermGhosttyCloseSurfaceCallback: ghostty_runtime_close_surface_cb = { _, _ in
}

private let momentermGhosttyReceiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
    guard let userdata = userdata, let ptr = ptr, len > 0 else {
        return
    }
    let bridge = Unmanaged<MomentermGhosttyHostBridge>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    let data = Data(bytes: ptr, count: len)
    DispatchQueue.main.async {
        bridge.owner?.onInput?(data)
    }
}

private let momentermGhosttyReceiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
    guard let userdata = userdata else {
        return
    }
    let bridge = Unmanaged<MomentermGhosttyHostBridge>
        .fromOpaque(userdata)
        .takeUnretainedValue()
    DispatchQueue.main.async {
        bridge.owner?.applyGridResize(columns: Int(cols), rows: Int(rows))
    }
}

final class LibGhosttyTerminalView: NSView {
    static let isCompiledIn = true

    var onInput: ((Data) -> Void)?
    var onGridResize: ((Int, Int) -> Void)?

    private var surface: ghostty_surface_t?
    private var hostBridge: MomentermGhosttyHostBridge?
    private var renderScheduled = false
    private var lastColumns = 0
    private var lastRows = 0

    var isRenderingAvailable: Bool {
        MomentermGhosttyRuntime.shared.app != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            buildSurfaceIfNeeded()
            fitToSize()
        } else {
            setFocused(false)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitToSize()
    }

    override func layout() {
        super.layout()
        fitToSize()
    }

    func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        receive(data)
    }

    func receive(_ data: Data) {
        buildSurfaceIfNeeded()
        guard let surface = surface else {
            return
        }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, base, UInt(buffer.count))
        }
        requestRender()
    }

    func fitToSize() {
        buildSurfaceIfNeeded()
        guard let surface = surface else {
            return
        }

        updateMetalLayerMetrics()
        let scale = backingScale()
        let pixelWidth = UInt32(max(1, floor(bounds.width * CGFloat(scale))))
        let pixelHeight = UInt32(max(1, floor(bounds.height * CGFloat(scale))))
        guard pixelWidth > 1, pixelHeight > 1 else {
            return
        }

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
        let size = ghostty_surface_size(surface)
        applyGridResize(columns: Int(size.columns), rows: Int(size.rows))
        requestRender()
    }

    func setFocused(_ focused: Bool) {
        guard let surface = surface else {
            return
        }
        ghostty_surface_set_focus(surface, focused)
        requestRender()
    }

    func requestRender() {
        guard surface != nil, !renderScheduled else {
            return
        }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.renderFrame()
        }
    }

    func applyGridResize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else {
            return
        }
        guard columns != lastColumns || rows != lastRows else {
            return
        }
        lastColumns = columns
        lastRows = rows
        onGridResize?(columns, rows)
    }

    func isSurfaceAttachedForSmokeTest() -> Bool {
        surface != nil
    }

    func usesMetalLayerForSmokeTest() -> Bool {
        if layer is CAMetalLayer {
            return true
        }
        guard let layer = layer else {
            return false
        }
        let className = NSStringFromClass(type(of: layer))
        return className.localizedCaseInsensitiveContains("IOSurface")
            || className.localizedCaseInsensitiveContains("Metal")
    }

    func gridSize() -> (columns: Int, rows: Int)? {
        guard lastColumns > 0, lastRows > 0 else {
            return nil
        }
        return (lastColumns, lastRows)
    }

    func releaseSurface() {
        if let surface = surface {
            ghostty_surface_free(surface)
        }
        surface = nil
        hostBridge = nil
        renderScheduled = false
        MomentermGhosttyRuntime.shared.unregister(self)
    }

    deinit {
        releaseSurface()
    }

    private func commonInit() {
        wantsLayer = true
        let metalLayer = CAMetalLayer()
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.clear.cgColor
        layer = metalLayer
        updateMetalLayerMetrics()
    }

    private func buildSurfaceIfNeeded() {
        guard surface == nil,
              let app = MomentermGhosttyRuntime.shared.app
        else {
            return
        }
        MomentermGhosttyRuntime.shared.register(self)

        let bridge = MomentermGhosttyHostBridge(owner: self)
        hostBridge = bridge

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(self).toOpaque()
            )
        )
        config.userdata = Unmanaged.passUnretained(bridge).toOpaque()
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = Unmanaged.passUnretained(bridge).toOpaque()
        config.receive_buffer = momentermGhosttyReceiveBufferCallback
        config.receive_resize = momentermGhosttyReceiveResizeCallback
        config.scale_factor = backingScale()
        config.font_size = 13
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        surface = ghostty_surface_new(app, &config)
        if let surface = surface {
            ghostty_surface_set_color_scheme(surface, GHOSTTY_COLOR_SCHEME_DARK)
            ghostty_surface_set_occlusion(surface, true)
        }
    }

    private func renderFrame() {
        renderScheduled = false
        guard let surface = surface else {
            return
        }
        MomentermGhosttyRuntime.shared.tick()
        ghostty_surface_refresh(surface)
        ghostty_surface_draw(surface)
        updateMetalLayerMetrics()
    }

    private func updateMetalLayerMetrics() {
        let scale = backingScale()
        layer?.contentsScale = CGFloat(scale)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.contentsScale = CGFloat(scale)
            metalLayer.drawableSize = CGSize(
                width: max(bounds.width * CGFloat(scale), 1),
                height: max(bounds.height * CGFloat(scale), 1)
            )
        }
    }

    private func backingScale() -> Double {
        Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0)
    }
}
#else
final class LibGhosttyTerminalView: NSView {
    static let isCompiledIn = false

    var onInput: ((Data) -> Void)?
    var onGridResize: ((Int, Int) -> Void)?
    var isRenderingAvailable: Bool { false }

    func receive(_ string: String) {}
    func receive(_ data: Data) {}
    func fitToSize() {}
    func setFocused(_ focused: Bool) {}
    func requestRender() {}
    func applyGridResize(columns: Int, rows: Int) {}
    func releaseSurface() {}
    func isSurfaceAttachedForSmokeTest() -> Bool { false }
    func usesMetalLayerForSmokeTest() -> Bool { false }
    func gridSize() -> (columns: Int, rows: Int)? { nil }
}
#endif
