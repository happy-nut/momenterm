import AppKit

// ANSI terminal rendering, extracted from MainWindowController (refactor step #2).
// Self-contained: depends only on the injected NativeTheme value type and AppKit.
// NativeTerminalFont supplies cell metrics; NativeAnsiRenderer parses ANSI escape
// sequences into styled NSAttributedString output. No MainWindowController coupling.

enum NativeTerminalFont {
    static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = baseFont(size: size)
        guard weight.rawValue >= NSFont.Weight.semibold.rawValue else {
            return base
        }
        let bold = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        return bold.pointSize == size ? bold : base
    }

    static func cellMetrics(size: CGFloat) -> (width: CGFloat, height: CGFloat) {
        let font = font(size: size, weight: .regular)
        let width = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
        let height = ceil(font.ascender - font.descender + font.leading)
        return (max(width, 1), max(height, 1))
    }

    private static func baseFont(size: CGFloat) -> NSFont {
        let candidates = [
            "Monaco",
            "Menlo",
            "SFMono-Regular",
            "D2Coding",
            "JetBrainsMono Nerd Font Mono",
            "MesloLGS NF"
        ]
        for name in candidates {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

final class NativeAnsiRenderer {
    private struct Style {
        var foreground: NSColor?
        var background: NSColor?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
    }

    private struct Cell {
        var text: String
        var style: Style
        var isWideContinuation = false

        var isBlank: Bool {
            text == " "
        }
    }

    private var theme: NativeTheme
    private var columns: Int
    private var rows: Int
    private var screen: [[Cell]]
    private var mainScreen: [[Cell]]?
    private var scrollback: [[Cell]] = []
    private var cursorRow = 0
    private var cursorColumn = 0
    private var savedCursor: (row: Int, column: Int)?
    private var style = Style()
    private var alternateScreen = false
    private var wraparound = true
    private var horizontalOverflowClipActive = false
    private var pendingResponses: [String] = []
    private let maxScrollbackLines = 2_000

    init(theme: NativeTheme, columns: Int = 120, rows: Int = 36) {
        self.theme = theme
        self.columns = max(columns, 20)
        self.rows = max(rows, 2)
        self.screen = []
        self.screen = Array(repeating: [], count: self.rows)
        for row in 0..<self.rows {
            self.screen[row] = blankLine()
        }
    }

    func resize(columns: Int, rows: Int) {
        self.columns = max(columns, 20)
        self.rows = max(rows, 2)
        resizeScreen()
    }

    func render(into output: NSMutableAttributedString) {
        output.setAttributedString(render())
    }

    func consumeResponses() -> [String] {
        let responses = pendingResponses
        pendingResponses.removeAll(keepingCapacity: true)
        return responses
    }

    func append(_ text: String, to output: NSMutableAttributedString) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            writeText(buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1b:
                flush()
                index = consumeEscape(in: scalars, from: index)
            case 0x0d:
                flush()
                cursorColumn = 0
                horizontalOverflowClipActive = false
                index += 1
            case 0x0a:
                flush()
                lineFeed()
                horizontalOverflowClipActive = false
                index += 1
            case 0x08, 0x7f:
                flush()
                cursorColumn = max(cursorColumn - 1, 0)
                horizontalOverflowClipActive = false
                index += 1
            default:
                if scalar.value >= 0x20 || scalar.value == 0x09 {
                    buffer.unicodeScalars.append(scalar)
                }
                index += 1
            }
        }
        flush()
        output.setAttributedString(render())
    }

    private func consumeEscape(in scalars: [UnicodeScalar], from index: Int) -> Int {
        guard index + 1 < scalars.count else {
            return index + 1
        }
        let introducer = scalars[index + 1]
        if introducer == "[" {
            var cursor = index + 2
            while cursor < scalars.count {
                let value = scalars[cursor].value
                if value >= 0x40 && value <= 0x7e {
                    let final = Character(scalars[cursor])
                    let raw = String(String.UnicodeScalarView(scalars[(index + 2)..<cursor]))
                    handleCSI(raw, final: final)
                    return cursor + 1
                }
                cursor += 1
            }
            return scalars.count
        }
        if introducer == "]" {
            var cursor = index + 2
            while cursor < scalars.count {
                if scalars[cursor].value == 0x07 {
                    return cursor + 1
                }
                if scalars[cursor].value == 0x1b, cursor + 1 < scalars.count, scalars[cursor + 1] == "\\" {
                    return cursor + 2
                }
                cursor += 1
            }
            return scalars.count
        }
        if ["P", "_", "^", "X"].contains(Character(introducer)) {
            return consumeUntilStringTerminator(in: scalars, from: index + 2)
        }
        switch Character(introducer) {
        case "7":
            savedCursor = (cursorRow, cursorColumn)
        case "8":
            restoreCursor()
        case "D":
            lineFeed()
            horizontalOverflowClipActive = false
        case "E":
            cursorColumn = 0
            lineFeed()
            horizontalOverflowClipActive = false
        case "M":
            reverseLineFeed()
            horizontalOverflowClipActive = false
        case "c":
            reset()
        default:
            break
        }
        return index + 2
    }

    private func consumeUntilStringTerminator(in scalars: [UnicodeScalar], from index: Int) -> Int {
        var cursor = index
        while cursor < scalars.count {
            if scalars[cursor].value == 0x1b, cursor + 1 < scalars.count, scalars[cursor + 1] == "\\" {
                return cursor + 2
            }
            cursor += 1
        }
        return scalars.count
    }

    private func handleCSI(_ raw: String, final: Character) {
        let parameters = parseParameters(raw)
        switch final {
        case "m":
            applySGR(parameters)
        case "H", "f":
            moveCursor(row: parameter(parameters, 0, default: 1) - 1, column: parameter(parameters, 1, default: 1) - 1)
        case "A":
            cursorRow = max(cursorRow - max(parameters.first ?? 1, 1), 0)
            horizontalOverflowClipActive = false
        case "B":
            cursorRow = min(cursorRow + max(parameters.first ?? 1, 1), rows - 1)
            horizontalOverflowClipActive = false
        case "C":
            moveCursorColumnClippingOverflow(cursorColumn + max(parameters.first ?? 1, 1))
        case "D":
            cursorColumn = max(cursorColumn - max(parameters.first ?? 1, 1), 0)
            horizontalOverflowClipActive = false
        case "E":
            cursorRow = min(cursorRow + max(parameters.first ?? 1, 1), rows - 1)
            cursorColumn = 0
            horizontalOverflowClipActive = false
        case "F":
            cursorRow = max(cursorRow - max(parameters.first ?? 1, 1), 0)
            cursorColumn = 0
            horizontalOverflowClipActive = false
        case "G":
            moveCursorColumnClippingOverflow(max((parameters.first ?? 1) - 1, 0))
        case "d":
            cursorRow = min(max((parameters.first ?? 1) - 1, 0), rows - 1)
            horizontalOverflowClipActive = false
        case "K":
            eraseLine(parameters.first ?? 0)
        case "J":
            eraseDisplay(parameters.first ?? 0)
        case "S":
            scrollUp(count: max(parameters.first ?? 1, 1))
        case "T":
            scrollDown(count: max(parameters.first ?? 1, 1))
        case "P":
            deleteCharacters(count: max(parameters.first ?? 1, 1))
        case "@":
            insertBlankCharacters(count: max(parameters.first ?? 1, 1))
        case "X":
            eraseCharacters(count: max(parameters.first ?? 1, 1))
        case "L":
            insertLines(count: max(parameters.first ?? 1, 1))
        case "M":
            deleteLines(count: max(parameters.first ?? 1, 1))
        case "s":
            savedCursor = (cursorRow, cursorColumn)
        case "u":
            restoreCursor()
        case "h":
            setMode(raw: raw, enabled: true)
        case "l":
            setMode(raw: raw, enabled: false)
        case "r":
            moveCursor(row: 0, column: 0)
        case "n":
            handleStatusReport(parameters)
        case "c":
            pendingResponses.append("\u{1b}[?1;2c")
        default:
            break
        }
    }

    private func writeText(_ value: String) {
        for character in value {
            if character == "\t" {
                let target = min(((cursorColumn / 8) + 1) * 8, columns)
                while cursorColumn < target {
                    put(" ")
                }
            } else {
                put(String(character), width: displayWidth(character))
            }
        }
    }

    private func put(_ text: String, width: Int = 1) {
        ensureCursor()
        let cellWidth = max(width, 1)
        if cellWidth > 1, cursorColumn + cellWidth > columns {
            cursorColumn = 0
            lineFeed()
            ensureCursor()
        }
        screen[cursorRow][cursorColumn] = Cell(text: text, style: style)
        if cellWidth > 1 {
            for offset in 1..<cellWidth where cursorColumn + offset < columns {
                screen[cursorRow][cursorColumn + offset] = Cell(text: " ", style: style, isWideContinuation: true)
            }
        }
        if cursorColumn == columns - 1 {
            // When pinned by an overflow move (e.g. zsh RPROMPT on a narrow pane),
            // overwrite the last cell in place instead of wrapping, so the text stays
            // on one line and inside the grid.
            if wraparound && !horizontalOverflowClipActive {
                cursorColumn = 0
                lineFeed()
            }
        } else {
            cursorColumn = min(cursorColumn + cellWidth, columns - 1)
        }
    }

    private func handleStatusReport(_ parameters: [Int]) {
        switch parameters.first ?? 0 {
        case 5:
            pendingResponses.append("\u{1b}[0n")
        case 6:
            pendingResponses.append("\u{1b}[\(cursorRow + 1);\(cursorColumn + 1)R")
        default:
            break
        }
    }

    private func lineFeed() {
        if cursorRow == rows - 1 {
            if !alternateScreen {
                scrollback.append(screen.removeFirst())
                trimScrollback()
            } else {
                screen.removeFirst()
            }
            screen.append(blankLine())
        } else {
            cursorRow += 1
        }
    }

    private func reverseLineFeed() {
        if cursorRow == 0 {
            screen.insert(blankLine(), at: 0)
            if screen.count > rows {
                screen.removeLast()
            }
        } else {
            cursorRow -= 1
        }
    }

    private func eraseLine(_ mode: Int) {
        ensureCursor()
        switch mode {
        case 1:
            for column in 0...cursorColumn {
                screen[cursorRow][column] = blankCell()
            }
        case 2:
            screen[cursorRow] = blankLine()
        default:
            for column in cursorColumn..<columns {
                screen[cursorRow][column] = blankCell()
            }
        }
    }

    private func eraseDisplay(_ mode: Int) {
        ensureCursor()
        switch mode {
        case 1:
            for row in 0..<cursorRow {
                screen[row] = blankLine()
            }
            for column in 0...cursorColumn {
                screen[cursorRow][column] = blankCell()
            }
        case 2, 3:
            screen = Array(repeating: blankLine(), count: rows)
            if mode == 3 {
                scrollback.removeAll(keepingCapacity: true)
            }
            moveCursor(row: 0, column: 0)
        default:
            for column in cursorColumn..<columns {
                screen[cursorRow][column] = blankCell()
            }
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows {
                    screen[row] = blankLine()
                }
            }
        }
    }

    private func eraseCharacters(count: Int) {
        ensureCursor()
        let end = min(cursorColumn + count, columns)
        guard cursorColumn < end else { return }
        for column in cursorColumn..<end {
            screen[cursorRow][column] = blankCell()
        }
    }

    private func deleteCharacters(count: Int) {
        ensureCursor()
        let count = min(count, columns - cursorColumn)
        guard count > 0 else { return }
        screen[cursorRow].removeSubrange(cursorColumn..<(cursorColumn + count))
        screen[cursorRow].append(contentsOf: Array(repeating: blankCell(), count: count))
    }

    private func insertBlankCharacters(count: Int) {
        ensureCursor()
        let count = min(count, columns - cursorColumn)
        guard count > 0 else { return }
        screen[cursorRow].insert(contentsOf: Array(repeating: blankCell(), count: count), at: cursorColumn)
        screen[cursorRow] = Array(screen[cursorRow].prefix(columns))
    }

    private func insertLines(count: Int) {
        let count = min(max(count, 1), rows - cursorRow)
        for _ in 0..<count {
            screen.insert(blankLine(), at: cursorRow)
            screen.removeLast()
        }
    }

    private func deleteLines(count: Int) {
        let count = min(max(count, 1), rows - cursorRow)
        for _ in 0..<count {
            screen.remove(at: cursorRow)
            screen.append(blankLine())
        }
    }

    private func scrollUp(count: Int) {
        for _ in 0..<count {
            if !alternateScreen {
                scrollback.append(screen.removeFirst())
                trimScrollback()
            } else {
                screen.removeFirst()
            }
            screen.append(blankLine())
        }
    }

    private func scrollDown(count: Int) {
        for _ in 0..<count {
            screen.insert(blankLine(), at: 0)
            screen.removeLast()
        }
    }

    private func moveCursor(row: Int, column: Int) {
        cursorRow = min(max(row, 0), rows - 1)
        cursorColumn = min(max(column, 0), columns - 1)
        horizontalOverflowClipActive = false
    }

    private func moveCursorColumnClippingOverflow(_ column: Int) {
        // Clamp absolute/relative column moves (CHA/CUF) into the grid. zsh RPROMPT
        // emits e.g. ESC[{cols+N}G before the right-aligned clock; on a narrow pane
        // that column exceeds `columns`. Clamp to the last cell and mark the cursor as
        // pinned so the RPROMPT text overwrites in place at the edge — staying visible
        // and on a single line — instead of being swallowed or wrapping onto the next
        // row. The pin clears on the next CR/LF (the normal end of a prompt paint).
        cursorColumn = min(max(column, 0), columns - 1)
        horizontalOverflowClipActive = column >= columns
    }

    private func restoreCursor() {
        guard let savedCursor = savedCursor else { return }
        moveCursor(row: savedCursor.row, column: savedCursor.column)
    }

    private func setMode(raw: String, enabled: Bool) {
        guard raw.hasPrefix("?") else {
            return
        }
        for value in parseParameters(raw) {
            switch value {
            case 7:
                wraparound = enabled
            case 47, 1047, 1049:
                if enabled {
                    if !alternateScreen {
                        mainScreen = screen
                        alternateScreen = true
                        screen = Array(repeating: blankLine(), count: rows)
                        moveCursor(row: 0, column: 0)
                    }
                } else if alternateScreen {
                    screen = mainScreen ?? Array(repeating: blankLine(), count: rows)
                    mainScreen = nil
                    alternateScreen = false
                    moveCursor(row: 0, column: 0)
                }
            default:
                break
            }
        }
    }

    private func parseParameters(_ raw: String) -> [Int] {
        let cleaned = raw
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: ">", with: "")
            .replacingOccurrences(of: "=", with: "")
        if cleaned.isEmpty {
            return [0]
        }
        return cleaned.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    }

    private func parameter(_ values: [Int], _ index: Int, default fallback: Int) -> Int {
        guard values.indices.contains(index), values[index] != 0 else {
            return fallback
        }
        return values[index]
    }

    private func applySGR(_ params: [Int]) {
        let values = params.isEmpty ? [0] : params
        var index = 0
        while index < values.count {
            let value = values[index]
            switch value {
            case 0:
                style = Style()
            case 1:
                style.bold = true
            case 2:
                style.dim = true
            case 3:
                style.italic = true
            case 4:
                style.underline = true
            case 22:
                style.bold = false
                style.dim = false
            case 23:
                style.italic = false
            case 24:
                style.underline = false
            case 30...37:
                style.foreground = xtermColor(value - 30)
            case 90...97:
                style.foreground = xtermColor(value - 90 + 8)
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = xtermColor(value - 40)
            case 100...107:
                style.background = xtermColor(value - 100 + 8)
            case 49:
                style.background = nil
            case 38, 48:
                let isForeground = value == 38
                if index + 2 < values.count, values[index + 1] == 5 {
                    setColor(xtermColor(values[index + 2]), foreground: isForeground)
                    index += 2
                } else if index + 4 < values.count, values[index + 1] == 2 {
                    setColor(NSColor(
                        calibratedRed: CGFloat(values[index + 2]) / 255.0,
                        green: CGFloat(values[index + 3]) / 255.0,
                        blue: CGFloat(values[index + 4]) / 255.0,
                        alpha: 1
                    ), foreground: isForeground)
                    index += 4
                }
            default:
                break
            }
            index += 1
        }
    }

    private func setColor(_ color: NSColor, foreground: Bool) {
        if foreground {
            style.foreground = color
        } else {
            style.background = color
        }
    }

    private func render() -> NSAttributedString {
        let output = NSMutableAttributedString()
        let scrollbackStart = alternateScreen ? scrollback.startIndex : firstNonBlankScrollbackLine()
        if scrollbackStart < scrollback.endIndex {
            for index in scrollbackStart..<scrollback.endIndex {
                append(line: scrollback[index], to: output)
                output.append(NSAttributedString(string: "\n", attributes: attributes(for: Style())))
            }
        }
        let lastRow = lastNonBlankScreenRow()
        if lastRow >= 0 {
            let firstRow = alternateScreen ? 0 : firstNonBlankScreenRow()
            for row in firstRow...lastRow {
                append(line: screen[row], to: output)
                if row < lastRow {
                    output.append(NSAttributedString(string: "\n", attributes: attributes(for: Style())))
                }
            }
        }
        return output
    }

    private func firstNonBlankScrollbackLine() -> Array<[Cell]>.Index {
        scrollback.firstIndex { line in
            line.contains { !$0.isBlank }
        } ?? scrollback.endIndex
    }

    private func append(line: [Cell], to output: NSMutableAttributedString) {
        let end = line.lastIndex(where: { !$0.isBlank }) ?? -1
        guard end >= 0 else {
            return
        }
        for index in 0...end {
            let cell = line[index]
            if cell.isWideContinuation {
                continue
            }
            output.append(NSAttributedString(string: cell.text, attributes: attributes(for: cell.style)))
        }
    }

    private func lastNonBlankScreenRow() -> Int {
        for row in stride(from: rows - 1, through: 0, by: -1) {
            if screen[row].contains(where: { !$0.isBlank }) {
                return row
            }
        }
        return -1
    }

    private func firstNonBlankScreenRow() -> Int {
        for row in 0..<rows {
            if screen[row].contains(where: { !$0.isBlank }) {
                return row
            }
        }
        return 0
    }

    private func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        var font = NativeTerminalFont.font(size: 13, weight: style.bold ? .semibold : .regular)
        if style.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.dim ? (style.foreground ?? theme.terminalForeground).withAlphaComponent(0.62) : (style.foreground ?? theme.terminalForeground)
        ]
        if let background = style.background {
            attrs[.backgroundColor] = background
        }
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func blankLine() -> [Cell] {
        Array(repeating: blankCell(), count: columns)
    }

    private func blankCell() -> Cell {
        Cell(text: " ", style: Style())
    }

    private func ensureCursor() {
        resizeScreen()
        cursorRow = min(max(cursorRow, 0), rows - 1)
        cursorColumn = min(max(cursorColumn, 0), columns - 1)
    }

    private func resizeScreen() {
        if screen.count < rows {
            screen.append(contentsOf: Array(repeating: blankLine(), count: rows - screen.count))
        } else if screen.count > rows {
            let overflow = screen.count - rows
            screen.removeFirst(overflow)
        }
        for index in screen.indices {
            if screen[index].count < columns {
                screen[index].append(contentsOf: Array(repeating: blankCell(), count: columns - screen[index].count))
            } else if screen[index].count > columns {
                screen[index] = Array(screen[index].prefix(columns))
            }
        }
    }

    private func trimScrollback() {
        if scrollback.count > maxScrollbackLines {
            scrollback.removeFirst(scrollback.count - maxScrollbackLines)
        }
    }

    private func reset() {
        style = Style()
        screen = Array(repeating: blankLine(), count: rows)
        scrollback.removeAll(keepingCapacity: true)
        mainScreen = nil
        alternateScreen = false
        wraparound = true
        horizontalOverflowClipActive = false
        pendingResponses.removeAll(keepingCapacity: true)
        moveCursor(row: 0, column: 0)
    }

    private func displayWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else {
            return 1
        }
        switch scalar.value {
        case 0x1100...0x115F,
             0x2329...0x232A,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F300...0x1FAFF:
            return 2
        default:
            return 1
        }
    }

    private func xtermColor(_ index: Int) -> NSColor {
        let base: [NSColor] = [
            NSColor(calibratedRed: 0.00, green: 0.00, blue: 0.00, alpha: 1),
            NSColor(calibratedRed: 0.80, green: 0.20, blue: 0.20, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.68, blue: 0.36, alpha: 1),
            NSColor(calibratedRed: 0.76, green: 0.62, blue: 0.25, alpha: 1),
            NSColor(calibratedRed: 0.25, green: 0.50, blue: 0.86, alpha: 1),
            NSColor(calibratedRed: 0.64, green: 0.42, blue: 0.82, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.65, blue: 0.74, alpha: 1),
            NSColor(calibratedRed: 0.78, green: 0.80, blue: 0.82, alpha: 1),
            NSColor(calibratedRed: 0.46, green: 0.49, blue: 0.52, alpha: 1),
            NSColor(calibratedRed: 0.96, green: 0.32, blue: 0.32, alpha: 1),
            NSColor(calibratedRed: 0.49, green: 0.82, blue: 0.50, alpha: 1),
            NSColor(calibratedRed: 0.90, green: 0.74, blue: 0.38, alpha: 1),
            NSColor(calibratedRed: 0.40, green: 0.62, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.79, green: 0.56, blue: 0.98, alpha: 1),
            NSColor(calibratedRed: 0.40, green: 0.80, blue: 0.88, alpha: 1),
            NSColor(calibratedRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        ]
        if index >= 0 && index < base.count {
            return base[index]
        }
        if index >= 16 && index <= 231 {
            let value = index - 16
            let r = value / 36
            let g = (value / 6) % 6
            let b = value % 6
            func channel(_ part: Int) -> CGFloat {
                part == 0 ? 0 : CGFloat(55 + part * 40) / 255.0
            }
            return NSColor(calibratedRed: channel(r), green: channel(g), blue: channel(b), alpha: 1)
        }
        if index >= 232 && index <= 255 {
            let gray = CGFloat(8 + (index - 232) * 10) / 255.0
            return NSColor(calibratedWhite: gray, alpha: 1)
        }
        return theme.terminalForeground
    }
}
