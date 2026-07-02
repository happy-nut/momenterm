import AppKit

// Content preview renderers, extracted from MainWindowController (refactor step #3).
// CSV tables, Markdown, and syntax highlighting -> styled NSAttributedString.
// Self-contained: depend only on the injected NativeTheme, MomentermDesign tokens,
// NativeLanguageRegistry, and AppKit. No MainWindowController coupling.

enum NativeCsvRenderer {
    private static let maxPreviewRows = 200
    private static let maxPreviewColumns = 18
    private static let maxCellWidth = 32

    static func render(_ source: String, language: String, theme: NativeTheme) -> NSAttributedString {
        let delimiter: Character = language == "tsv" ? "\t" : ","
        let rows = parseRows(source, delimiter: delimiter)
        let output = NSMutableAttributedString()
        let title = language == "tsv" ? "TSV Preview" : "CSV Preview"
        let columnCount = rows.map(\.count).max() ?? 0
        let visibleColumns = min(columnCount, maxPreviewColumns)
        let visibleRows = Array(rows.prefix(maxPreviewRows))

        appendLine(title, to: output, color: theme.primaryText, font: MomentermDesign.Fonts.UI.title.font)
        var summary = "rows: \(rows.count), columns: \(columnCount)"
        if rows.count > visibleRows.count || columnCount > visibleColumns {
            summary += "  |  showing first \(visibleRows.count) rows, \(visibleColumns) columns"
        }
        appendLine(summary, to: output, color: theme.secondaryText)
        appendLine("", to: output, color: theme.secondaryText)

        guard visibleColumns > 0 else {
            appendLine("No rows.", to: output, color: theme.secondaryText)
            return output
        }

        let widths = columnWidths(rows: visibleRows, columnCount: visibleColumns)
        for (index, row) in visibleRows.enumerated() {
            let background = index == 0 ? theme.codeHeaderBackground : nil
            let color = index == 0 ? theme.primaryText : theme.codeText
            appendLine(format(row: row, widths: widths), to: output, color: color, background: background)
            if index == 0 {
                appendLine(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "), to: output, color: theme.secondaryText, background: theme.codeBackground)
            }
        }
        return output
    }

    private static func parseRows(_ source: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var cell = ""
        var inQuotes = false
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if character == "\"" {
                if inQuotes, next < source.endIndex, source[next] == "\"" {
                    cell.append("\"")
                    index = source.index(after: next)
                    continue
                }
                inQuotes.toggle()
                index = next
            } else if character == delimiter && !inQuotes {
                row.append(cell)
                cell = ""
                index = next
            } else if (character == "\n" || character == "\r") && !inQuotes {
                row.append(cell)
                if row.contains(where: { !$0.isEmpty }) {
                    rows.append(row)
                }
                row = []
                cell = ""
                if character == "\r", next < source.endIndex, source[next] == "\n" {
                    index = source.index(after: next)
                } else {
                    index = next
                }
            } else {
                cell.append(character)
                index = next
            }
        }

        if !cell.isEmpty || !row.isEmpty {
            row.append(cell)
            if row.contains(where: { !$0.isEmpty }) {
                rows.append(row)
            }
        }
        return rows
    }

    private static func columnWidths(rows: [[String]], columnCount: Int) -> [Int] {
        (0..<columnCount).map { column in
            let longest = rows.map { row in
                clipped(row.indices.contains(column) ? row[column] : "", width: maxCellWidth).count
            }.max() ?? 4
            return min(max(max(4, longest), column == 0 ? 6 : 4), maxCellWidth)
        }
    }

    private static func format(row: [String], widths: [Int]) -> String {
        widths.enumerated().map { column, width in
            let raw = row.indices.contains(column) ? row[column] : ""
            let value = clipped(raw, width: width)
            let padding = String(repeating: " ", count: max(0, width - value.count))
            return value + padding
        }.joined(separator: "  ")
    }

    private static func clipped(_ cell: String, width: Int) -> String {
        let normalized = cell
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard normalized.count > width else {
            return normalized
        }
        guard width > 3 else {
            return String(normalized.prefix(width))
        }
        return String(normalized.prefix(width - 3)) + "..."
    }

    private static func appendLine(
        _ text: String,
        to output: NSMutableAttributedString,
        color: NSColor,
        background: NSColor? = nil,
        font: NSFont = MomentermDesign.Fonts.code
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ]
        if let background = background {
            attributes[.backgroundColor] = background
        }
        output.append(NSAttributedString(string: text + "\n", attributes: attributes))
    }
}

enum NativeMarkdownRenderer {
    static func render(_ source: String, theme: NativeTheme) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = source.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            let rendered = renderLine(line, theme: theme)
            output.append(rendered)
            if index < lines.count - 1 {
                output.append(NSAttributedString(string: "\n", attributes: [
                    .font: markdownBodyFont,
                    .foregroundColor: theme.primaryText
                ]))
            }
        }
        return output
    }

    private static func renderLine(_ line: String, theme: NativeTheme) -> NSAttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return NSAttributedString(string: "", attributes: baseAttributes(theme: theme))
        }

        let headingLevel = headingLevel(in: line)
        if headingLevel > 0 {
            let marker = String(repeating: "#", count: headingLevel) + " "
            let title = String(line.dropFirst(marker.count))
            return inline(title, font: headingFont(level: headingLevel), color: theme.primaryText, theme: theme)
        }

        if let checkbox = checklistLine(line) {
            let rendered = "\(checkbox.checked ? "☑" : "☐") \(checkbox.text)"
            return inline(rendered, font: markdownBodyFont, color: theme.primaryText, theme: theme)
        }

        if let bullet = bulletLine(line) {
            return inline("• \(bullet)", font: markdownBodyFont, color: theme.primaryText, theme: theme)
        }

        if trimmed.hasPrefix(">") {
            let text = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return inline(String(text), font: NSFontManager.shared.convert(markdownBodyFont, toHaveTrait: .italicFontMask), color: theme.secondaryText, theme: theme)
        }

        return inline(line, font: markdownBodyFont, color: theme.primaryText, theme: theme)
    }

    private static func headingLevel(in line: String) -> Int {
        var count = 0
        for character in line {
            if character == "#" {
                count += 1
                continue
            }
            return character == " " && count > 0 && count <= 6 ? count : 0
        }
        return 0
    }

    // Body matches the code font (Monaco 14) so Markdown files sit at the same size and
    // family as every other file in the code pane. Headings step up only modestly for
    // emphasis (monospaced so the family stays consistent) instead of the old 22/18/15.
    static let markdownBodyFont = MomentermDesign.Fonts.code

    private static func headingFont(level: Int) -> NSFont {
        switch level {
        case 1:
            return NSFont.monospacedSystemFont(ofSize: 17, weight: .semibold)
        case 2:
            return NSFont.monospacedSystemFont(ofSize: 15, weight: .semibold)
        default:
            return NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
        }
    }

    private static func checklistLine(_ line: String) -> (checked: Bool, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let prefixes = [
            ("- [ ] ", false),
            ("* [ ] ", false),
            ("- [x] ", true),
            ("- [X] ", true),
            ("* [x] ", true),
            ("* [X] ", true)
        ]
        for (prefix, checked) in prefixes where trimmed.hasPrefix(prefix) {
            return (checked, String(trimmed.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func bulletLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return String(trimmed.dropFirst(2))
        }
        return nil
    }

    private static func inline(_ source: String, font: NSFont, color: NSColor, theme: NativeTheme) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var index = source.startIndex
        while index < source.endIndex {
            if source[index...].hasPrefix("**"),
               let end = source[source.index(index, offsetBy: 2)..<source.endIndex].range(of: "**")?.lowerBound {
                let start = source.index(index, offsetBy: 2)
                output.append(NSAttributedString(string: String(source[start..<end]), attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize, weight: .bold),
                    .foregroundColor: color
                ]))
                index = source.index(end, offsetBy: 2)
            } else if source[index] == "`",
                      let end = source[source.index(after: index)..<source.endIndex].firstIndex(of: "`") {
                let start = source.index(after: index)
                output.append(NSAttributedString(string: String(source[start..<end]), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: max(11, font.pointSize - 1), weight: .regular),
                    .foregroundColor: theme.codeText,
                    .backgroundColor: theme.codeBackground
                ]))
                index = source.index(after: end)
            } else {
                output.append(NSAttributedString(string: String(source[index]), attributes: [
                    .font: font,
                    .foregroundColor: color
                ]))
                index = source.index(after: index)
            }
        }
        return output
    }

    private static func baseAttributes(theme: NativeTheme) -> [NSAttributedString.Key: Any] {
        [
            .font: markdownBodyFont,
            .foregroundColor: theme.primaryText
        ]
    }
}

enum NativeSyntaxHighlighter {
    static func highlight(_ source: String, language: String, theme: NativeTheme) -> NSAttributedString {
        let output = NSMutableAttributedString(string: source, attributes: [
            .font: MomentermDesign.Fonts.code,
            .foregroundColor: theme.codeText,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ])
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        guard fullRange.length > 0 else {
            return output
        }
        for rule in rulesForLanguage(NativeLanguageRegistry.normalized(language), theme: theme) {
            apply(pattern: rule.pattern, color: rule.color, options: rule.options, in: nsSource, range: fullRange, output: output)
        }
        return output
    }

    private struct Rule {
        let pattern: String
        let color: NSColor
        let options: NSRegularExpression.Options

        init(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = [.anchorsMatchLines]) {
            self.pattern = pattern
            self.color = color
            self.options = options
        }
    }

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()

    private static func rulesForLanguage(_ language: String, theme: NativeTheme) -> [Rule] {
        var rules = [
            Rule(keywordRegex(language: language), theme.syntaxKeyword),
            Rule(#"\b0x[0-9a-fA-F]+\b|\b\d+(\.\d+)?([eE][+-]?\d+)?\b"#, theme.syntaxNumber)
        ]
        switch language {
        case "swift", "kotlin", "java", "scala", "groovy", "python", "ruby", "go", "rust", "c", "cpp", "objc", "csharp", "php":
            rules.append(Rule(#"@\w+(?:\.\w+)*\b"#, theme.syntaxMetadata))
        case "json":
            rules.append(Rule(#""([^"\\]|\\.)*"\s*:"#, theme.syntaxKeyword))
        case "yaml", "toml", "ini", "properties", "dotenv", "gitignore":
            rules.append(Rule(#"^\s*[A-Za-z0-9_.-]+(?=\s*[:=])"#, theme.syntaxKeyword))
            rules.append(Rule(#"^\s*[-*]\s+"#, theme.syntaxNumber))
        case "markup", "xml", "svg":
            rules.append(Rule(#"</?[A-Za-z][A-Za-z0-9:._-]*|/?>"#, theme.syntaxKeyword))
            rules.append(Rule(#"\s[A-Za-z_:][A-Za-z0-9:._-]*(?=\=)"#, theme.syntaxNumber))
        case "css", "scss", "sass":
            rules.append(Rule(#"#[0-9a-fA-F]{3,8}\b|\b\d+(\.\d+)?(px|em|rem|vh|vw|%|ms|s|deg)?\b"#, theme.syntaxNumber))
            rules.append(Rule(#"[-A-Za-z_][A-Za-z0-9_-]*(?=\s*:)"#, theme.syntaxKeyword))
            rules.append(Rule(#"\.[A-Za-z_][A-Za-z0-9_-]*|#[A-Za-z_][A-Za-z0-9_-]*"#, theme.syntaxString))
        case "markdown":
            rules.append(Rule(#"^#{1,6}\s+.*$|^\s*[-*+]\s+|\[[^\]]+\]\([^)]+\)|`[^`]+`"#, theme.syntaxKeyword))
        case "csv", "tsv":
            rules.append(Rule(#"[^,\t\n\r]+"#, theme.syntaxString))
        case "http":
            rules.append(Rule(#"^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|TRACE)\s+\S+"#, theme.syntaxKeyword))
            rules.append(Rule(#"^\s*[A-Za-z0-9_-]+(?=\s*:)"#, theme.syntaxNumber))
            rules.append(Rule(#"\{\{[A-Za-z0-9_.-]+\}\}"#, theme.syntaxString))
        case "sql":
            rules.append(Rule(#"\b(SELECT|FROM|WHERE|JOIN|LEFT|RIGHT|INNER|OUTER|INSERT|INTO|UPDATE|DELETE|CREATE|ALTER|DROP|TABLE|VIEW|INDEX|VALUES|SET|GROUP|ORDER|BY|HAVING|LIMIT|OFFSET|AS|ON|AND|OR|NOT|NULL|TRUE|FALSE)\b"#, theme.syntaxKeyword, options: [.anchorsMatchLines, .caseInsensitive]))
        case "shell", "dockerfile", "makefile":
            rules.append(Rule(#"\$[A-Za-z_][A-Za-z0-9_]*|\$\{[^}]+\}"#, theme.syntaxNumber))
        default:
            break
        }
        rules.append(Rule(stringRegex(language: language), theme.syntaxString))
        rules.append(Rule(commentRegex(language: language), theme.syntaxComment, options: [.anchorsMatchLines, .dotMatchesLineSeparators]))
        return rules
    }

    private static func keywordRegex(language: String) -> String {
        switch language {
        case "swift":
            return #"\b(class|struct|enum|protocol|extension|func|let|var|if|else|guard|switch|case|return|throw|throws|try|catch|import|private|final|static|init|for|while|in|do|as|is|nil|true|false)\b"#
        case "typescript", "javascript":
            return #"\b(class|function|const|let|var|if|else|return|import|export|from|async|await|try|catch|throw|new|type|interface|extends|implements|true|false|null|undefined)\b"#
        case "kotlin":
            return #"\b(class|object|interface|fun|val|var|if|else|when|is|as|return|throw|try|catch|finally|import|package|private|internal|public|override|data|sealed|suspend|true|false|null)\b"#
        case "java", "scala", "groovy":
            return #"\b(class|interface|enum|record|public|private|protected|static|final|void|int|long|double|float|boolean|char|new|if|else|switch|case|return|throw|throws|try|catch|finally|import|package|extends|implements|true|false|null|val|var|def)\b"#
        case "python":
            return #"\b(class|def|lambda|if|elif|else|for|while|in|is|not|and|or|return|yield|try|except|finally|raise|import|from|as|with|pass|break|continue|True|False|None)\b"#
        case "ruby":
            return #"\b(class|module|def|end|if|elsif|else|unless|case|when|do|return|yield|begin|rescue|ensure|raise|require|include|extend|true|false|nil)\b"#
        case "go":
            return #"\b(package|import|func|type|struct|interface|var|const|if|else|switch|case|return|defer|go|select|chan|range|for|map|true|false|nil)\b"#
        case "rust":
            return #"\b(fn|let|mut|struct|enum|trait|impl|use|mod|pub|crate|if|else|match|return|for|while|loop|in|async|await|move|Self|self|true|false|None|Some|Ok|Err)\b"#
        case "c", "cpp", "objc", "csharp":
            return #"\b(class|struct|enum|namespace|using|public|private|protected|static|const|auto|void|int|long|double|float|bool|char|if|else|switch|case|return|throw|try|catch|new|delete|true|false|null|nullptr|nil|interface|var|string)\b"#
        case "php":
            return #"\b(class|function|public|private|protected|static|const|if|else|elseif|switch|case|return|throw|try|catch|finally|new|use|namespace|extends|implements|true|false|null)\b"#
        case "shell":
            return #"\b(if|then|else|elif|fi|for|while|do|done|case|esac|function|select|in|export|local|readonly|return|exit|true|false)\b"#
        case "dockerfile":
            return #"^\s*(FROM|RUN|CMD|LABEL|EXPOSE|ENV|ADD|COPY|ENTRYPOINT|VOLUME|USER|WORKDIR|ARG|ONBUILD|STOPSIGNAL|HEALTHCHECK|SHELL)\b"#
        case "makefile":
            return #"\b(ifeq|ifneq|ifdef|ifndef|else|endif|include|export|override|define|endef)\b|^[A-Za-z0-9_.-]+(?=\s*:)"#
        case "css", "scss", "sass":
            return #"\b(@import|@media|@supports|@keyframes|from|to|important|var|calc|rgba?|hsla?|url)\b"#
        case "markup", "xml", "svg":
            return #"<!\[CDATA\[|<!DOCTYPE|<!--|-->|</?[A-Za-z][A-Za-z0-9:._-]*"#
        case "json", "yaml", "toml", "ini", "properties", "dotenv":
            return #"\b(true|false|null|yes|no|on|off)\b"#
        case "http":
            return #"\b(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|HTTP|Host|Content-Type|Authorization|Accept)\b"#
        case "graphql":
            return #"\b(query|mutation|subscription|fragment|on|type|interface|union|enum|input|schema|scalar|true|false|null)\b"#
        case "markdown", "csv", "tsv", "gitignore":
            return #"(?!)"#
        default:
            return #"\b(class|struct|enum|func|function|const|let|var|if|else|return|import|export|true|false|null|nil)\b"#
        }
    }

    private static func stringRegex(language: String) -> String {
        switch language {
        case "python", "ruby", "shell":
            return #"\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*'|`[^`]*`"#
        default:
            return #"\"([^\"\\]|\\.)*\"|'([^'\\]|\\.)*'"#
        }
    }

    private static func commentRegex(language: String) -> String {
        switch language {
        case "python", "ruby", "shell", "yaml", "toml", "ini", "properties", "dotenv", "makefile", "dockerfile", "gitignore":
            return #"(?m)#[^\n\r]*$"#
        case "sql":
            return #"(?m)--[^\n\r]*$|/\*[\s\S]*?\*/"#
        case "markup", "xml", "svg", "markdown":
            return #"<!--[\s\S]*?-->"#
        default:
            return #"(?m)//[^\n\r]*$|/\*[\s\S]*?\*/"#
        }
    }

    private static func apply(pattern: String, color: NSColor, options: NSRegularExpression.Options, in source: NSString, range: NSRange, output: NSMutableAttributedString) {
        guard !pattern.isEmpty,
              let regex = cachedRegex(pattern: pattern, options: options)
        else {
            return
        }
        regex.enumerateMatches(in: source as String, options: [], range: range) { match, _, _ in
            guard let match = match else {
                return
            }
            output.addAttribute(.foregroundColor, value: color, range: match.range)
        }
    }

    private static func cachedRegex(pattern: String, options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue)\u{0}\(pattern)"
        regexLock.lock()
        if let cached = regexCache[key] {
            regexLock.unlock()
            return cached
        }
        regexLock.unlock()
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        regexLock.lock()
        regexCache[key] = regex
        regexLock.unlock()
        return regex
    }
}
