import AppKit
import Foundation

// Helper types extracted from MainWindowController (refactor Phase 2 — move-only).
// (private extension JSONValue stays in the core file: its file-scoped boolValue/arrayValue
// are used by MainWindowController's own code and would lose visibility if moved.)

final class NativeUTF8StreamDecoder {
    private var pending = Data()

    func decode(_ data: Data) -> String {
        guard !data.isEmpty || !pending.isEmpty else {
            return ""
        }
        pending.append(data)
        let validLength = Self.validUTF8PrefixLength(in: pending)
        guard validLength > 0 else {
            return ""
        }
        let prefix = pending.prefix(validLength)
        pending.removeFirst(validLength)
        return String(decoding: prefix, as: UTF8.self)
    }

    func flush() -> String {
        guard !pending.isEmpty else {
            return ""
        }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return text
    }

    private static func validUTF8PrefixLength(in data: Data) -> Int {
        let bytes = [UInt8](data)
        var index = 0
        var lastValidIndex = 0

        while index < bytes.count {
            let byte = bytes[index]
            let length: Int
            if byte < 0x80 {
                length = 1
            } else if byte >= 0xC2 && byte <= 0xDF {
                length = 2
            } else if byte >= 0xE0 && byte <= 0xEF {
                length = 3
            } else if byte >= 0xF0 && byte <= 0xF4 {
                length = 4
            } else {
                index += 1
                lastValidIndex = index
                continue
            }

            guard index + length <= bytes.count else {
                break
            }

            var valid = true
            for offset in 1..<length where bytes[index + offset] & 0xC0 != 0x80 {
                valid = false
                break
            }
            if valid {
                let second = length > 1 ? bytes[index + 1] : 0
                if (byte == 0xE0 && second < 0xA0)
                    || (byte == 0xED && second > 0x9F)
                    || (byte == 0xF0 && second < 0x90)
                    || (byte == 0xF4 && second > 0x8F) {
                    valid = false
                }
            }

            if valid {
                index += length
                lastValidIndex = index
            } else {
                index += 1
                lastValidIndex = index
            }
        }

        return lastValidIndex
    }
}

extension NSColor {
    convenience init?(hex: String?) {
        guard let hex = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              hex.count == 6,
              let value = Int(hex, radix: 16)
        else {
            return nil
        }
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }

    func hexString(fallback: String) -> String {
        guard let rgb = usingColorSpace(.deviceRGB) else {
            return fallback
        }
        return String(
            format: "#%02x%02x%02x",
            Int(max(0, min(255, rgb.redComponent * 255))),
            Int(max(0, min(255, rgb.greenComponent * 255))),
            Int(max(0, min(255, rgb.blueComponent * 255)))
        )
    }
}
