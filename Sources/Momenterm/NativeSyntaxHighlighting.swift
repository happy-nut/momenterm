import Foundation

enum NativeLanguageRegistry {
    static let filenameLanguageMap: [String: String] = [
        "dockerfile": "dockerfile",
        "containerfile": "dockerfile",
        "makefile": "makefile",
        "gnumakefile": "makefile",
        "rakefile": "ruby",
        "gemfile": "ruby",
        "podfile": "ruby",
        "brewfile": "ruby",
        "jenkinsfile": "groovy",
        ".gitignore": "gitignore",
        ".gitattributes": "gitignore",
        ".env": "dotenv",
        ".editorconfig": "ini"
    ]

    static let extensionLanguageMap: [String: String] = [
        "swift": "swift",
        "m": "objc",
        "mm": "objc",
        "h": "c",
        "c": "c",
        "cc": "cpp",
        "cpp": "cpp",
        "cxx": "cpp",
        "hpp": "cpp",
        "cs": "csharp",
        "java": "java",
        "kt": "kotlin",
        "kts": "kotlin",
        "scala": "scala",
        "groovy": "groovy",
        "gradle": "groovy",
        "go": "go",
        "rs": "rust",
        "py": "python",
        "pyw": "python",
        "rb": "ruby",
        "php": "php",
        "js": "javascript",
        "jsx": "javascript",
        "mjs": "javascript",
        "cjs": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "vue": "markup",
        "svelte": "markup",
        "html": "markup",
        "htm": "markup",
        "xml": "markup",
        "xhtml": "markup",
        "plist": "xml",
        "svg": "svg",
        "css": "css",
        "scss": "scss",
        "sass": "sass",
        "less": "css",
        "json": "json",
        "jsonc": "json",
        "json5": "json",
        "map": "json",
        "yaml": "yaml",
        "yml": "yaml",
        "toml": "toml",
        "ini": "ini",
        "cfg": "ini",
        "conf": "ini",
        "properties": "properties",
        "env": "dotenv",
        "md": "markdown",
        "mdx": "markdown",
        "txt": "text",
        "log": "text",
        "csv": "csv",
        "tsv": "tsv",
        "sql": "sql",
        "graphql": "graphql",
        "gql": "graphql",
        "sh": "shell",
        "bash": "shell",
        "zsh": "shell",
        "fish": "shell",
        "command": "shell",
        "http": "http",
        "rest": "http",
        "y": "yacc",
        "l": "lex"
    ]

    static let darculaHighlightedLanguages: Set<String> = [
        "swift", "objc", "c", "cpp", "csharp", "java", "kotlin", "scala", "groovy",
        "go", "rust", "python", "ruby", "php", "javascript", "typescript",
        "markup", "xml", "svg", "css", "scss", "sass", "json", "yaml", "toml",
        "ini", "properties", "dotenv", "markdown", "csv", "tsv", "sql", "graphql",
        "shell", "http", "dockerfile", "makefile", "gitignore", "yacc", "lex"
    ]

    static var darculaHighlightedExtensions: Set<String> {
        Set(extensionLanguageMap.filter { darculaHighlightedLanguages.contains($0.value) }.map(\.key))
    }

    static func language(forPath path: String) -> String {
        let normalizedPath = path.replacingOccurrences(of: "\\", with: "/")
        let fileName = URL(fileURLWithPath: normalizedPath).lastPathComponent.lowercased()
        if let language = filenameLanguageMap[fileName] {
            return language
        }
        let ext = URL(fileURLWithPath: normalizedPath).pathExtension.lowercased()
        guard !ext.isEmpty else {
            return "text"
        }
        return extensionLanguageMap[ext] ?? "text"
    }

    static func normalized(_ language: String) -> String {
        switch language.lowercased() {
        case "kt", "kts":
            return "kotlin"
        case "js", "jsx", "mjs", "cjs":
            return "javascript"
        case "ts", "tsx":
            return "typescript"
        case "html", "htm", "vue", "svelte":
            return "markup"
        case "xml", "plist":
            return "xml"
        case "yml":
            return "yaml"
        case "bash", "zsh", "fish":
            return "shell"
        case "rest":
            return "http"
        default:
            return language.lowercased()
        }
    }
}
