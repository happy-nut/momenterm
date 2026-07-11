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

        // Terminal appearance is customizable: background/foreground follow the selected
        // app theme, and the caret style/blink come from Settings. All read at startup
        // (the ghostty runtime config is a singleton), each with a fallback to the historical
        // default so a missing/invalid value is a zero-regression no-op. Monaco has no Hangul
        // glyphs, so the repeated font-family entries give a Korean-capable fallback chain.
        let bgHex = Self.hexString(ThemeManager.shared.theme.terminalBackground) ?? "222831"
        let fgHex = Self.hexString(ThemeManager.shared.theme.terminalForeground) ?? "eeeeee"
        // Neutral grey selection (theme secondary surface) instead of the old olive/yellow
        // highlight, which read as unnecessary emphasis.
        let selectionHex = "214283"
        let allowedCursorStyles = ["block", "bar", "underline"]
        let cursorStyle = UserDefaults.standard.string(forKey: "momenterm.terminal.cursorStyle")
            .flatMap { allowedCursorStyles.contains($0) ? $0 : nil } ?? "block"
        let cursorBlink = (UserDefaults.standard.object(forKey: "momenterm.terminal.cursorBlink") as? Bool) ?? true
        let contents = """
        font-family = Monaco
        font-family = Apple SD Gothic Neo
        font-family = AppleGothic
        font-size = 13
        font-thicken = true
        scrollback-limit = 1048576
        background = \(bgHex)
        foreground = \(fgHex)
        selection-background = \(selectionHex)
        selection-foreground = \(fgHex)
        cursor-style = \(cursorStyle)
        cursor-style-blink = \(cursorBlink)
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
        runtime.write_clipboard_cb = momentermGhosttyWriteClipboardCallback

        app = ghostty_app_new(&runtime, config)
        if let app = app {
            ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)
        }
    }

    // "rrggbb" for a ghostty config color line. Returns nil if the color can't be
    // expressed in sRGB, so the caller keeps the historical hardcoded default.
    private static func hexString(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return nil
        }
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "%02x%02x%02x", r, g, b)
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

private let momentermGhosttyWriteClipboardCallback: ghostty_runtime_write_clipboard_cb = { _, _, items, count, _ in
    guard let items = items, count > 0 else { return }
    for i in 0..<Int(count) {
        let item = items.advanced(by: i).pointee
        guard let mime = item.mime, let data = item.data else { continue }
        if String(cString: mime).hasPrefix("text/") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
            return
        }
    }
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
    private var reportedSurfaceVisibility: Bool?
    private var lastColumns = 0
    private var lastRows = 0
#if DEBUG
    // Counts mouse events forwarded into the ghostty surface so a smoke test can assert the
    // NSTextView on top actually relays its drag-select gesture here (the selection-bug fix).
    private(set) var forwardedMouseEventCountForSmokeTest = 0
    private(set) var preeditTextForSmokeTest = ""
    private(set) var surfaceVisibilityForSmokeTest = false
#endif

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
            buildSurfaceIfNeeded(initiallyVisible: false)
            fitToSize()
            setSurfaceVisibility(true)
        } else {
            setSurfaceVisibility(false)
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

    @discardableResult
    func receive(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8) else {
            return false
        }
        return receive(data)
    }

    @discardableResult
    func receive(_ data: Data) -> Bool {
        buildSurfaceIfNeeded()
        guard let surface = surface else {
            return false
        }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, base, UInt(buffer.count))
        }
        requestRender()
        return true
    }

    @discardableResult
    func fitToSize() -> Bool {
        buildSurfaceIfNeeded()
        guard let surface = surface else {
            return false
        }

        updateMetalLayerMetrics()
        let scale = backingScale()
        let pixelWidth = UInt32(max(1, floor(bounds.width * CGFloat(scale))))
        let pixelHeight = UInt32(max(1, floor(bounds.height * CGFloat(scale))))
        guard pixelWidth > 1, pixelHeight > 1 else {
            return false
        }

        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, pixelWidth, pixelHeight)
        let size = ghostty_surface_size(surface)
        applyGridResize(columns: Int(size.columns), rows: Int(size.rows))
        requestRender()
        return size.columns > 0 && size.rows > 0
    }

    func setFocused(_ focused: Bool) {
        guard let surface = surface else {
            return
        }
        ghostty_surface_set_focus(surface, focused)
        requestRender()
    }

    func setPreedit(_ text: String) {
#if DEBUG
        preeditTextForSmokeTest = text
#endif
        buildSurfaceIfNeeded()
        guard let surface = surface else {
            return
        }
        if text.isEmpty {
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            text.withCString { pointer in
                ghostty_surface_preedit(surface, pointer, UInt(text.utf8.count))
            }
        }
        requestRender()
    }

    func imeRectOnScreen() -> NSRect? {
        buildSurfaceIfNeeded()
        guard let surface = surface, let window = window else {
            return nil
        }
        let metrics = NativeTerminalFont.cellMetrics(size: 13)
        var x = 0.0
        var y = 0.0
        var width = Double(metrics.width)
        var height = Double(metrics.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewRect = NSRect(
            x: CGFloat(x),
            y: bounds.height - CGFloat(y),
            width: max(CGFloat(width), 0),
            height: max(CGFloat(height), metrics.height)
        )
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    // Mouse forwarding for text selection. The app's NSTextView sits on top of this Metal
    // surface (z-order) and owns keyboard/IME focus, so it relays its mouse gesture here.
    // ghostty owns the visible grid and renders the selection highlight itself; these three
    // entry points drive press/drag/release and read the resulting selection back out.
    func forwardMouseButton(_ event: NSEvent, pressed: Bool) {
        buildSurfaceIfNeeded()
        guard let surface = surface else {
            return
        }
        let state = pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE
        // Position must precede the button so ghostty starts the selection at the click cell.
        sendMousePos(event, surface: surface)
        ghostty_surface_mouse_button(surface, state, GHOSTTY_MOUSE_LEFT, Self.mouseMods(event.modifierFlags))
#if DEBUG
        forwardedMouseEventCountForSmokeTest += 1
#endif
        requestRender()
    }

    func forwardMouseDrag(_ event: NSEvent) {
        guard let surface = surface else {
            return
        }
        sendMousePos(event, surface: surface)
#if DEBUG
        forwardedMouseEventCountForSmokeTest += 1
#endif
        requestRender()
    }

    // Reads ghostty's current selection (if any) into the general pasteboard. Returns true when
    // a non-empty selection was copied. Called on mouse-up so a completed drag lands on the
    // clipboard, matching macOS terminal behavior, and reused by the app's Cmd-C path.
    @discardableResult
    func copySelectionToPasteboard() -> Bool {
        guard let surface = surface, ghostty_surface_has_selection(surface) else {
            return false
        }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else {
            return false
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let ptr = text.text, text.text_len > 0 else {
            return false
        }
        let selected = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(text.text_len)), as: UTF8.self)
        guard !selected.isEmpty else {
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
        return true
    }

    // Non-empty only while ghostty holds a live selection; lets the app's Cmd-C prefer the
    // ghostty selection over the (invisible, stale) NSTextView selection when a surface exists.
    func hasSelection() -> Bool {
        guard let surface = surface else {
            return false
        }
        return ghostty_surface_has_selection(surface)
    }

    // Converts an NSEvent's window location into ghostty surface coordinates. ghostty expects
    // logical points in the surface's own space with a top-left origin, so we convert from the
    // window into this view and flip Y (AppKit is bottom-left). Content scale is applied by
    // ghostty via set_content_scale, so we pass points, not backing pixels.
    private func sendMousePos(_ event: NSEvent, surface: ghostty_surface_t) {
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, Double(pos.x), Double(bounds.height - pos.y), Self.mouseMods(event.modifierFlags))
    }

    private static func mouseMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    func requestRender() {
        guard surface != nil, reportedSurfaceVisibility == true, !renderScheduled else {
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

#if DEBUG
    func isSurfaceAttachedForSmokeTest() -> Bool {
        surface != nil
    }

    func surfaceTextForSmokeTest() -> String? {
        guard let surface = surface else {
            return nil
        }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else {
            return nil
        }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text, text.text_len > 0 else {
            return ""
        }
        return String(
            decoding: UnsafeRawBufferPointer(start: pointer, count: Int(text.text_len)),
            as: UTF8.self
        )
    }

    func mouseForwardCountForSmokeTest() -> Int {
        forwardedMouseEventCountForSmokeTest
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
#endif

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
        reportedSurfaceVisibility = nil
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

    private func buildSurfaceIfNeeded(initiallyVisible: Bool? = nil) {
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
            reportedSurfaceVisibility = nil
            setSurfaceVisibility(initiallyVisible ?? (window != nil))
        }
    }

    private func setSurfaceVisibility(_ visible: Bool) {
        guard let surface = surface, reportedSurfaceVisibility != visible else {
            return
        }
        reportedSurfaceVisibility = visible
        ghostty_surface_set_occlusion(surface, visible)
#if DEBUG
        surfaceVisibilityForSmokeTest = visible
#endif
        if visible {
            requestRender()
        }
    }

    private func renderFrame() {
        renderScheduled = false
        guard let surface = surface, reportedSurfaceVisibility == true else {
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

    @discardableResult
    func receive(_ string: String) -> Bool { false }
    @discardableResult
    func receive(_ data: Data) -> Bool { false }
    @discardableResult
    func fitToSize() -> Bool { false }
    func setFocused(_ focused: Bool) {}
    func setPreedit(_ text: String) {}
    func imeRectOnScreen() -> NSRect? { nil }
    func forwardMouseButton(_ event: NSEvent, pressed: Bool) {}
    func forwardMouseDrag(_ event: NSEvent) {}
    @discardableResult
    func copySelectionToPasteboard() -> Bool { false }
    func hasSelection() -> Bool { false }
    func requestRender() {}
    func applyGridResize(columns: Int, rows: Int) {}
    func releaseSurface() {}
#if DEBUG
    func isSurfaceAttachedForSmokeTest() -> Bool { false }
    func surfaceTextForSmokeTest() -> String? { nil }
    func usesMetalLayerForSmokeTest() -> Bool { false }
    func mouseForwardCountForSmokeTest() -> Int { 0 }
    var preeditTextForSmokeTest: String { "" }
    var surfaceVisibilityForSmokeTest: Bool { false }
#endif
    func gridSize() -> (columns: Int, rows: Int)? { nil }
}
#endif
