import Foundation

// TEMP DIAGNOSTIC: remove after backspace/IME bug is root-caused.
// Shared key/IME trace logger. Kept in its own file (rather than inside
// NativePtyManager) so isolation smokes can compile the call sites in
// NativeTextViews / NativePtyManager without pulling in the whole PTY manager.
// When the IME bug is closed, delete this file and its call sites together.
func momentermKeyDebug(_ message: @autoclosure () -> String) {
    let line = message() + "\n"
    guard let data = line.data(using: .utf8) else { return }
    let path = "/tmp/momenterm-keydebug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
