import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let ignoreWhitespace = args.contains("--ignore-whitespace")
let repoArg = args.first { !$0.hasPrefix("--") } ?? FileManager.default.currentDirectoryPath
let repo = URL(fileURLWithPath: repoArg)
let core = NativeReviewCore()

do {
    let review = try core.build(root: repo, ignoreWhitespace: ignoreWhitespace)
    let payload: JSONValue = .object([
        "root": .string(review.root ?? ""),
        "html": .string(review.html),
        "files": .number(Double(review.files)),
        "hunks": .number(Double(review.hunks)),
        "signature": .string(review.signature),
        "generatedAt": .string(review.generatedAt),
        "lazyBodies": .array(review.lazyBodies.map { .string($0) }),
        "lazySourceData": .string(review.lazySourceData),
        "update": review.update ?? .null
    ])
    print(payload.jsonString())
} catch {
    fputs("momenterm ab dump failed: \(error)\n", stderr)
    exit(1)
}
