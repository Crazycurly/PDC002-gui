import Foundation

/// 64-byte HID report framing for the PDC002 programmer.
///
/// Layout: [0..1]=FF 55, [2..7]=timestamp, [8]=command, [9]=payload length,
/// [10...]=payload, [62]=sum(buf[8..<62])&0xFF, [63]=sum(buf[0..<62])&0xFF.
///
/// The timestamp bytes are NOT cosmetic: the write-session commands
/// (startWrite/endWrite/write) are silently ignored by the device unless
/// bytes 2..4 carry a live timestamp, even though reads tolerate zeros.
/// They are filled exactly like the reference tool (see `FrameClock`).
public enum Frame {
    public static let length = 64
    public static let maxPayload = 52
    public static let zeroTimestamp: [UInt8] = [0, 0, 0, 0, 0, 0]

    public static func build(
        command: UInt8, payload: [UInt8], timestamp: [UInt8] = zeroTimestamp
    ) -> [UInt8] {
        precondition(payload.count <= maxPayload, "payload too long")
        precondition(timestamp.count == 6, "timestamp must be 6 bytes")
        var buf = [UInt8](repeating: 0, count: length)
        buf[0] = 0xFF
        buf[1] = 0x55
        for (i, b) in timestamp.enumerated() { buf[2 + i] = b }
        buf[8] = command
        // The official tool declares length 250 for the reset command.
        buf[9] = command == Command.reset.rawValue ? 250 : UInt8(payload.count)
        for (i, b) in payload.enumerated() { buf[10 + i] = b }
        buf[62] = UInt8(buf[8..<62].reduce(0) { $0 &+ Int($1) } & 0xFF)
        buf[63] = UInt8(buf[0..<62].reduce(0) { $0 &+ Int($1) } & 0xFF)
        return buf
    }
}

public enum Command: UInt8 {
    case progMode = 3
    case endWrite = 4
    case startWrite = 5
    case delete = 8
    case write = 9
    case readInfo = 10
    case readBulk = 11
    case reset = 23
}

/// Produces the 6 timestamp bytes the device expects, matching the formula
/// in reference/PDC002/pdc002.py: bytes 2..4 are fractions of the absolute
/// Unix time, bytes 5..7 are time relative to a baseline taken when the
/// device was opened. The clock source is injectable so tests are
/// deterministic.
public final class FrameClock: @unchecked Sendable {
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var baseline: TimeInterval

    public init(now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }) {
        self.now = now
        self.baseline = now()
    }

    public func timestamp() -> [UInt8] {
        let absts = now()
        lock.lock()
        // The reference rebaselines whenever the seconds byte wraps to 255.
        if UInt64(absts) & 0xFF == 255 { baseline = absts }
        let rel = max(0, absts - baseline)
        lock.unlock()
        return [
            UInt8(UInt64(absts) & 0xFF),
            UInt8(UInt64(absts * 1000) & 0xFF),
            UInt8(UInt64(absts * 1_000_000) & 0xFF),
            UInt8(UInt64(rel * 100) & 0xFF),
            UInt8((UInt64(rel * 1000) % 100) & 0xFF),
            UInt8(UInt64(rel * 1_000_000) & 0xFF),
        ]
    }
}
