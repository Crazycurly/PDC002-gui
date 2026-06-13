import Foundation

/// A decoded firmware image: the raw bytes the device stores, plus the
/// decoded .pd1s container header it came with.
public struct Firmware: Equatable, Sendable {
    /// 48 decoded header bytes, starting with the "gzutapp" magic.
    public let header: Data
    /// Raw firmware body written to the device (53,248 bytes for PDC002).
    public let body: Data

    public init(header: Data, body: Data) {
        self.header = header
        self.body = body
    }

    /// Build date stored at header bytes 7..10 (year LE16, month, day).
    public var buildDate: (year: Int, month: Int, day: Int) {
        (Int(header[7]) | Int(header[8]) << 8, Int(header[9]), Int(header[10]))
    }

    public var buildDateString: String {
        let d = buildDate
        return String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
    }
}

/// The WITRN .pd1s firmware container: the whole file is passed through a
/// fixed 256-byte substitution table. Decoded layout: "gzutapp" magic,
/// build date, padding (48 bytes total), then the raw firmware body.
public enum PD1S {
    public static let magic: [UInt8] = Array("gzutapp".utf8)
    public static let headerSize = 48
    /// PDC002 firmware is always 52 KB; other sizes are rejected so a
    /// truncated or foreign file can't be flashed.
    public static let expectedBodySize = 53248

    public enum DecodeError: Error, LocalizedError, Equatable {
        case tooShort
        case badMagic
        case unexpectedBodySize(Int)

        public var errorDescription: String? {
            switch self {
            case .tooShort:
                return "File is too short to be a .pd1s firmware image."
            case .badMagic:
                return "Not a .pd1s firmware image (magic mismatch)."
            case .unexpectedBodySize(let n):
                return "Unexpected firmware size (\(n) bytes, expected \(expectedBodySize))."
            }
        }
    }

    public static func decode(_ data: Data) throws -> Firmware {
        guard data.count > headerSize else { throw DecodeError.tooShort }
        var decoded = [UInt8](repeating: 0, count: data.count)
        for (i, b) in data.enumerated() {
            decoded[i] = sboxInverse[Int(b)]
        }
        guard Array(decoded[0..<magic.count]) == magic else { throw DecodeError.badMagic }
        let body = Data(decoded[headerSize...])
        guard body.count == expectedBodySize else {
            throw DecodeError.unexpectedBodySize(body.count)
        }
        return Firmware(header: Data(decoded[0..<headerSize]), body: body)
    }

    public static func encode(_ firmware: Firmware) -> Data {
        var encoded = Data(capacity: firmware.header.count + firmware.body.count)
        for b in firmware.header { encoded.append(sbox[Int(b)]) }
        for b in firmware.body { encoded.append(sbox[Int(b)]) }
        return encoded
    }
}
