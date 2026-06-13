import Foundation

/// One entry of the charger's recorded capability list, decoded from the
/// 4-byte mode words the PDC002 stores in its config block. WITRN re-encodes
/// the charger's USB-PD PDOs into its own layout, so the bit math here mirrors
/// the reverse-engineered `readModes()` decode in pdc-control rather than the
/// raw PD spec. Voltages are millivolts, currents milliamps.
public enum PDO: Equatable, Sendable {
    /// A fixed-voltage PDO (e.g. 5 V / 9 V / 20 V).
    case fixed(millivolts: Int, maxMilliamps: Int)
    /// A PPS / programmable APDO with an adjustable voltage window.
    case pps(minMillivolts: Int, maxMillivolts: Int, maxMilliamps: Int)

    /// Decode one 32-bit little-endian mode word. The top two bits select
    /// variable (PPS) vs fixed; the remaining fields are scaled exactly like
    /// the reference decoder (centivolts/centiamps), then promoted to mV/mA.
    public init(word: UInt32) {
        if (word & 0xC000_0000) == 0xC000_0000 {
            self = .pps(
                minMillivolts: Int((word & 0x0000_FF80) >> 7) * 50,
                maxMillivolts: Int((word & 0x01FF_0000) >> 16) * 50,
                maxMilliamps: Int(word & 0x0000_007F) * 50)
        } else {
            self = .fixed(
                millivolts: Int((word & 0x0007_FE00) >> 9) * 25,
                maxMilliamps: Int(word & 0x0000_01FF) * 10)
        }
    }

    public var isPPS: Bool {
        if case .pps = self { return true }
        return false
    }
}

/// Which voltage the cable requests on attach. The config stores this in
/// byte 1: four sentinel values pick a strategy, anything else is a 0-based
/// index into the recorded PDO list (the reference decoder prints it as
/// "PDO #(byte+1)"). The 0xA3 "arbitrary" value was confirmed on hardware —
/// a cable configured to a PPS voltage reads back 0xA3 with the target in the
/// saved-voltage field.
public enum PPSSelection: Equatable, Hashable, Sendable {
    case lowest     // 0xA0 — request the lowest advertised voltage
    case highest    // 0xA1 — request the highest advertised voltage
    case rotate     // 0xA2 — poll through the advertised voltages
    case arbitrary  // 0xA3 — request the saved PPS/programmable voltage
    case pdo(index: Int)

    public init(byte: UInt8) {
        switch byte {
        case 0xA0: self = .lowest
        case 0xA1: self = .highest
        case 0xA2: self = .rotate
        case 0xA3: self = .arbitrary
        default: self = .pdo(index: Int(byte))
        }
    }

    public var byte: UInt8 {
        switch self {
        case .lowest: return 0xA0
        case .highest: return 0xA1
        case .rotate: return 0xA2
        case .arbitrary: return 0xA3
        case .pdo(let index): return UInt8(truncatingIfNeeded: index)
        }
    }

    /// True when the selection targets a concrete voltage (the arbitrary PPS
    /// voltage or a specific PDO) rather than a min/max/rotate strategy.
    public var carriesTargetVoltage: Bool {
        switch self {
        case .arbitrary, .pdo: return true
        case .lowest, .highest, .rotate: return false
        }
    }
}

/// The 52-byte configuration block the "online" (PC-configurable) firmware
/// keeps at flash 0xFC00. It holds the PDO list the cable recorded from the
/// charger it was last plugged into, the selected request mode, the saved
/// target voltage, and a trailing additive checksum.
///
/// Layout (matching pdc-control's `readModes` and the official tool's
/// captured config write in reference/PDC002/traces/pps-config.txt):
///
///     [0]      marker (0xA0)
///     [1]      selection (see PPSSelection)
///     [2..3]   saved target voltage, little-endian millivolts
///     [5]      number of recorded PDOs
///     [7+4n]   PDO n, 32-bit little-endian mode word
///     [35]     charger info; PD version = ((byte >> 6) & 3) + 1
///     [51]     checksum: low byte of the sum of bytes [0..50]
public struct PPSConfig: Equatable, Sendable {
    public static let size = 52
    /// Room for 11 four-byte PDO words between byte 7 and the byte-51 checksum.
    public static let maxPDOCount = (size - 7) / 4

    /// The raw on-device block; the source of truth for re-encoding.
    public let raw: [UInt8]

    public init(block: [UInt8]) throws {
        guard block.count == Self.size else { throw FlashError.shortResponse }
        self.raw = block
    }

    private init(unchecked block: [UInt8]) {
        self.raw = block
    }

    /// True when the page is erased (all 0xFF) — i.e. no charger has been
    /// recorded yet, or the firmware isn't the PC-configurable one.
    public var isErased: Bool { raw.allSatisfy { $0 == 0xFF } }

    public var selection: PPSSelection { PPSSelection(byte: raw[1]) }

    /// Saved target voltage in millivolts (little-endian uint16 at [2..3]).
    public var savedMillivolts: Int { Int(raw[2]) | Int(raw[3]) << 8 }

    /// Charger PD revision (1 = PD1.0 ... ), or nil on an erased page.
    public var pdVersion: Int? {
        isErased ? nil : Int((raw[35] >> 6) & 0x3) + 1
    }

    /// The recorded PDO list, clamped to the bytes that actually fit.
    public var pdos: [PDO] {
        guard !isErased else { return [] }
        let count = min(Int(raw[5]), Self.maxPDOCount)
        return (0..<count).map { i in
            let base = 7 + i * 4
            let word = UInt32(raw[base]) | UInt32(raw[base + 1]) << 8
                | UInt32(raw[base + 2]) << 16 | UInt32(raw[base + 3]) << 24
            return PDO(word: word)
        }
    }

    /// The adjustable window (min, max millivolts) for an arbitrary voltage:
    /// the widest recorded PPS PDO (the one with the highest max), so a charger
    /// that advertises several PPS ranges (e.g. 5–11 V and 5–20 V) exposes the
    /// full programmable span rather than just the first/narrowest entry. nil
    /// when no PPS PDO was recorded.
    public var ppsRange: (minMillivolts: Int, maxMillivolts: Int)? {
        var widest: (minMillivolts: Int, maxMillivolts: Int)?
        for pdo in pdos {
            if case .pps(let low, let high, _) = pdo,
               high > (widest?.maxMillivolts ?? Int.min) {
                widest = (low, high)
            }
        }
        return widest
    }

    /// The XOR-checksum byte (51) over bytes [0..50], the value the device
    /// stores at the end of the block and validates when the cable attaches.
    public static func checksum(of block: [UInt8]) -> UInt8 {
        block[0..<51].reduce(0, ^)
    }

    /// Produce an updated block with a new selection and saved voltage,
    /// preserving every other byte (notably the recorded PDO list) and
    /// re-deriving the checksum.
    ///
    /// Byte 51 is an XOR of bytes [0..50] — verified against the captured
    /// config writes and a real-charger dump (all three blocks satisfy
    /// `[51] == XOR[0..50]`). An earlier additive-sum guess happened to match
    /// the 0xA0→0xA1 selection flip (a single low-bit change, where add and XOR
    /// agree) but produces a wrong byte for a multi-bit voltage change, which
    /// the cable then rejects — falling back to its minimum (5 V) output.
    public func updating(selection: PPSSelection, savedMillivolts: Int) -> PPSConfig {
        var block = raw
        block[1] = selection.byte
        block[2] = UInt8(savedMillivolts & 0xFF)
        block[3] = UInt8((savedMillivolts >> 8) & 0xFF)
        block[51] = Self.checksum(of: block)
        return PPSConfig(unchecked: block)
    }
}
