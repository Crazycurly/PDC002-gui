import XCTest
@testable import PDC002Kit

final class SBoxTests: XCTestCase {
    func testTablesAreInverseBijections() {
        XCTAssertEqual(Set(sbox).count, 256)
        XCTAssertEqual(Set(sboxInverse).count, 256)
        for v in 0..<256 {
            XCTAssertEqual(Int(sboxInverse[Int(sbox[v])]), v)
        }
    }

    /// Every bundled preset decodes to a gzutapp image with a 52 KB body
    /// and re-encodes byte-for-byte to the original file.
    func testAllBundledPresetsRoundTrip() throws {
        XCTAssertEqual(FirmwareCatalog.presets.count, 28)
        for preset in FirmwareCatalog.presets {
            let url = try XCTUnwrap(FirmwareCatalog.url(for: preset), preset.id)
            let original = try Data(contentsOf: url)
            let firmware = try PD1S.decode(original)
            XCTAssertEqual(firmware.body.count, PD1S.expectedBodySize, preset.id)
            XCTAssertEqual(PD1S.encode(firmware), original, preset.id)
        }
    }

    func testBuildDates() throws {
        let fixed9 = try FirmwareCatalog.load(XCTUnwrap(FirmwareCatalog.preset(id: "2.0-fixed-9v")))
        XCTAssertEqual(fixed9.buildDateString, "2020-03-30")
        let epr20 = try FirmwareCatalog.load(XCTUnwrap(FirmwareCatalog.preset(id: "2.1-epr-avs-20v")))
        XCTAssertEqual(epr20.buildDateString, "2023-07-14")
    }

    func testDecodeRejectsGarbage() {
        XCTAssertThrowsError(try PD1S.decode(Data(repeating: 0x41, count: 100)))
        XCTAssertThrowsError(try PD1S.decode(Data([0x67])))
    }

    func testIdentifyMatchesPreset() throws {
        let preset = try XCTUnwrap(FirmwareCatalog.preset(id: "2.0-fixed-12v"))
        let body = try FirmwareCatalog.load(preset).body
        XCTAssertEqual(FirmwareCatalog.identify(body: body)?.id, preset.id)
        XCTAssertNil(FirmwareCatalog.identify(body: Data(repeating: 0, count: PD1S.expectedBodySize)))
    }
}

final class FrameTests: XCTestCase {
    // OUT frames captured from the official Windows tool flashing the 9 V
    // firmware (reference/PDC002/traces/9V.txt). Bytes 2-7 are timestamps
    // and bytes past the payload are uninitialized buffer junk; both are
    // covered by the checksums and ignored by the device.
    static let capturedProgMode = [UInt8](hex:
        "ff55ea09802641f003000040000000000000000000000000b0f276004d13001006cd0010000000c00000000000000000030000000000004000000000f8cc7593")
    static let capturedWrite = [UInt8](hex:
        "ff55ebda203012fc092d002c000828e0070020712d0008792d00084d3900087d2d00087f2d0008812d0008000000000000000000000000008c0a000060fa87fe")
    static let capturedReset = [UInt8](hex:
        "ff55ee7d814d192017fa8504ef38d276b09c2201000000001831e10000000000b0f27600c0033b75ffffffffb0f276009732dd00e20405008001000000005319")

    func testChecksumFormulaMatchesCapturedFrames() {
        for frame in [Self.capturedProgMode, Self.capturedWrite, Self.capturedReset] {
            XCTAssertEqual(frame.count, 64)
            XCTAssertEqual(Int(frame[62]), frame[8..<62].reduce(0) { $0 + Int($1) } & 0xFF)
            XCTAssertEqual(Int(frame[63]), frame[0..<62].reduce(0) { $0 + Int($1) } & 0xFF)
        }
    }

    /// buildFrame, given the captured frame's own timestamp bytes, must
    /// reproduce its header, timestamp, command, length, and payload, with
    /// checksums computed over the live timestamp (the device validates
    /// byte 63 over the whole frame, so the timestamp must be checksummed).
    func testBuildFrameMatchesCapturedWriteFrame() {
        let captured = Self.capturedWrite
        let payloadLen = Int(captured[9])
        let payload = Array(captured[10..<(10 + payloadLen)])
        let timestamp = Array(captured[2..<8])
        let built = Frame.build(command: captured[8], payload: payload, timestamp: timestamp)

        XCTAssertEqual(built.count, 64)
        XCTAssertEqual(Array(built[0..<2]), [0xFF, 0x55])
        XCTAssertEqual(Array(built[2..<8]), timestamp)
        XCTAssertEqual(Array(built[8..<(10 + payloadLen)]), Array(captured[8..<(10 + payloadLen)]))
        XCTAssertEqual(Array(built[(10 + payloadLen)..<62]), [UInt8](repeating: 0, count: 52 - payloadLen))
        XCTAssertEqual(Int(built[62]), built[8..<62].reduce(0) { $0 + Int($1) } & 0xFF)
        XCTAssertEqual(Int(built[63]), built[0..<62].reduce(0) { $0 + Int($1) } & 0xFF)
    }

    /// Regression guard for the timeout bug: write-session frames must carry
    /// a live (non-zero) timestamp, because the device ignores them otherwise.
    func testClockProducesNonZeroTimestamp() {
        let clock = FrameClock(now: { 1_700_000_000.123456 })
        let bytes = clock.timestamp()
        XCTAssertEqual(bytes.count, 6)
        XCTAssertNotEqual(Array(bytes[0..<3]), [0, 0, 0])
    }

    /// The reset command declares payload length 250 like the official tool.
    func testResetFrameDeclaresLength250() {
        XCTAssertEqual(Self.capturedReset[8], Command.reset.rawValue)
        XCTAssertEqual(Self.capturedReset[9], 250)
        let built = Frame.build(command: Command.reset.rawValue, payload: [1, 2, 3])
        XCTAssertEqual(built[9], 250)
    }
}

final class CommandsTests: XCTestCase {
    func testPageAddresses() {
        let addrs = PDC002Commands.pageAddresses()
        XCTAssertEqual(addrs.count, 52)
        XCTAssertEqual(addrs.first, 0x2C)
        XCTAssertEqual(addrs.last, 0xF8)
    }

    /// The chunk sequence for the 9 V firmware must match the sequence the
    /// official tool produced (derived from reference/PDC002/firmware/9V.raw
    /// via pdc002.py's write() address logic; fixture: 9v-chunks.txt with
    /// one "addr0 addr1 length" line per chunk).
    func testWriteChunksMatchOfficial9VSequence() throws {
        let preset = try XCTUnwrap(FirmwareCatalog.preset(id: "2.0-fixed-9v"))
        let body = try FirmwareCatalog.load(preset).body
        let chunks = PDC002Commands.writeChunks(for: body)

        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "9v-chunks", withExtension: "txt", subdirectory: "Resources"))
        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n")
            .map { line -> (UInt8, UInt8, Int) in
                let parts = line.split(separator: " ").map { Int($0)! }
                return (UInt8(parts[0]), UInt8(parts[1]), parts[2])
            }

        XCTAssertEqual(chunks.count, expected.count)
        XCTAssertEqual(chunks.count, 1352)
        var offset = 0
        for (chunk, exp) in zip(chunks, expected) {
            XCTAssertEqual(chunk.addr0, exp.0)
            XCTAssertEqual(chunk.addr1, exp.1)
            XCTAssertEqual(chunk.data.count, exp.2)
            XCTAssertEqual(chunk.data, body.subdata(in: offset..<(offset + exp.2)))
            offset += exp.2
        }
        XCTAssertEqual(offset, body.count)
    }

    func testReadFirmwareReassembles52KB() async throws {
        let body = Data((0..<PDC002Commands.firmwareSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
        let device = MockDevice(flash: body)
        let commands = PDC002Commands(transport: device, settleNanoseconds: 0)
        let read = try await commands.readFirmware()
        XCTAssertEqual(read, body)
    }

    /// Full flash sequence against the mock device: erase, write, read-back
    /// verify, reset.
    func testFlashWritesAndVerifies() async throws {
        let preset = try XCTUnwrap(FirmwareCatalog.preset(id: "2.0-fixed-9v"))
        let body = try FirmwareCatalog.load(preset).body
        let device = MockDevice(flash: Data(repeating: 0xFF, count: PDC002Commands.firmwareSize))
        let commands = PDC002Commands(transport: device, settleNanoseconds: 0)
        try await commands.flash(body: body, verify: true)
        let flashed = await device.flashContents
        XCTAssertEqual(flashed, body)
        let wasReset = await device.didReset
        XCTAssertTrue(wasReset)
    }
}

final class PPSConfigTests: XCTestCase {
    /// The config block the official tool wrote/read back when selecting the
    /// "max" mode, captured in traces/pps-config.txt: marker 0xA0, selection
    /// 0xA1, saved 5.000 V (0x1388), no recorded PDOs, checksum 0x65.
    static func traceBlock(selectionByte: UInt8, checksum: UInt8) -> [UInt8] {
        var block = [UInt8](repeating: 0xFF, count: PPSConfig.size)
        block[0] = 0xA0
        block[1] = selectionByte
        block[2] = 136; block[3] = 19  // 5000 mV, little-endian
        block[4] = 0; block[5] = 0; block[6] = 0
        block[35] = 0
        block[51] = checksum
        return block
    }
    static let traceBlockMin = traceBlock(selectionByte: 0xA0, checksum: 100)
    static let traceBlockMax = traceBlock(selectionByte: 0xA1, checksum: 101)

    func testDecodesCapturedConfigBlock() throws {
        let config = try PPSConfig(block: Self.traceBlockMax)
        XCTAssertFalse(config.isErased)
        XCTAssertEqual(config.selection, .highest)
        XCTAssertEqual(config.savedMillivolts, 5000)
        XCTAssertEqual(config.pdVersion, 1)
        XCTAssertTrue(config.pdos.isEmpty)
    }

    func testDecodesFixedAndPPSEntries() throws {
        var block = [UInt8](repeating: 0xFF, count: PPSConfig.size)
        block[0] = 0xA0
        block[1] = 0           // selection: PDO index 0
        block[2] = 136; block[3] = 19
        block[5] = 2           // two recorded PDOs
        // Fixed 5.00 V / 3.00 A  -> word 0x0001912C (little-endian).
        block[7] = 0x2C; block[8] = 0x91; block[9] = 0x01; block[10] = 0x00
        // PPS 3.30–11.00 V / 3.00 A -> word 0xC0DC213C (little-endian).
        block[11] = 0x3C; block[12] = 0x21; block[13] = 0xDC; block[14] = 0xC0
        block[35] = 0x80       // PD version bits -> PD3

        let config = try PPSConfig(block: block)
        XCTAssertEqual(config.selection, .pdo(index: 0))
        XCTAssertEqual(config.pdVersion, 3)
        XCTAssertEqual(config.pdos, [
            .fixed(millivolts: 5000, maxMilliamps: 3000),
            .pps(minMillivolts: 3300, maxMillivolts: 11000, maxMilliamps: 3000),
        ])
    }

    func testErasedPageDecodesAsEmpty() throws {
        let config = try PPSConfig(block: [UInt8](repeating: 0xFF, count: PPSConfig.size))
        XCTAssertTrue(config.isErased)
        XCTAssertNil(config.pdVersion)
        XCTAssertTrue(config.pdos.isEmpty)
    }

    /// Re-encoding "min" -> "max" must reproduce the captured "max" block,
    /// including the trailing checksum (0x64 -> 0x65), confirming the additive
    /// delta recompute matches the device.
    func testUpdateReproducesCapturedWrite() throws {
        let min = try PPSConfig(block: Self.traceBlockMin)
        let updated = min.updating(selection: .highest, savedMillivolts: 5000)
        XCTAssertEqual(updated.raw, Self.traceBlockMax)
    }

    func testSelectionByteRoundTrips() {
        let cases: [PPSSelection] = [.lowest, .highest, .rotate, .arbitrary, .pdo(index: 0), .pdo(index: 5)]
        for sel in cases {
            XCTAssertEqual(PPSSelection(byte: sel.byte), sel)
        }
        // 0xA3 is the arbitrary-voltage sentinel, not PDO index 163.
        XCTAssertEqual(PPSSelection(byte: 0xA3), .arbitrary)
    }

    /// Decode of the block read off a real cable on a PD3 PPS charger
    /// (RealDeviceTests dump): 0xA3 arbitrary, 7.40 V saved, six PDOs ending
    /// in a 3.30–21.00 V PPS range.
    func testDecodesRealChargerBlock() throws {
        let raw: [UInt8] = [
            160, 163, 232, 28, 1, 6, 0, 44, 145, 1, 10, 44, 209, 2, 0, 44, 193, 3,
            0, 44, 177, 4, 0, 69, 65, 6, 0, 60, 33, 164, 201, 0, 0, 0, 0, 166, 255,
            255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 229,
        ]
        let config = try PPSConfig(block: raw)
        XCTAssertEqual(config.selection, .arbitrary)
        XCTAssertEqual(config.savedMillivolts, 7400)
        XCTAssertEqual(config.pdVersion, 3)
        XCTAssertEqual(config.pdos, [
            .fixed(millivolts: 5000, maxMilliamps: 3000),
            .fixed(millivolts: 9000, maxMilliamps: 3000),
            .fixed(millivolts: 12000, maxMilliamps: 3000),
            .fixed(millivolts: 15000, maxMilliamps: 3000),
            .fixed(millivolts: 20000, maxMilliamps: 3250),
            .pps(minMillivolts: 3300, maxMillivolts: 21000, maxMilliamps: 3000),
        ])
        XCTAssertEqual(config.ppsRange?.minMillivolts, 3300)
        XCTAssertEqual(config.ppsRange?.maxMillivolts, 21000)
    }

    /// Setting an arbitrary PPS voltage from the real block: 0xA3 stays, the
    /// saved voltage updates, the PDO list is preserved, and the additive
    /// checksum tracks the change.
    func testUpdateArbitraryVoltagePreservesPDOList() throws {
        let raw: [UInt8] = [
            160, 163, 232, 28, 1, 6, 0, 44, 145, 1, 10, 44, 209, 2, 0, 44, 193, 3,
            0, 44, 177, 4, 0, 69, 65, 6, 0, 60, 33, 164, 201, 0, 0, 0, 0, 166, 255,
            255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 229,
        ]
        let config = try PPSConfig(block: raw)
        let updated = config.updating(selection: .arbitrary, savedMillivolts: 9000)
        XCTAssertEqual(updated.selection, .arbitrary)
        XCTAssertEqual(updated.savedMillivolts, 9000)
        XCTAssertEqual(updated.pdos, config.pdos)           // PDO list intact
        // Byte 2 went 232 -> (9000 & 0xFF)=40, byte 3 28 -> 35: net delta to
        // the checksum is (40-232)+(35-28) = -185, 229-185 = 44.
        XCTAssertEqual(updated.raw[51], 44)
    }

    func testReadPPSConfigReturnsBlock() async throws {
        let device = MockDevice(
            flash: Data(repeating: 0xFF, count: PDC002Commands.firmwareSize),
            config: Self.traceBlockMax)
        let commands = PDC002Commands(transport: device, settleNanoseconds: 0)
        let config = try await commands.readPPSConfig()
        XCTAssertEqual(config.raw, Self.traceBlockMax)
        XCTAssertEqual(config.selection, .highest)
    }

    /// Full read-modify-write-verify against the mock: starting from the
    /// "min" block, selecting "max" must leave the device holding the "max"
    /// block and never trigger a reset.
    func testConfigurePPSWritesAndVerifies() async throws {
        let device = MockDevice(
            flash: Data(repeating: 0xFF, count: PDC002Commands.firmwareSize),
            config: Self.traceBlockMin)
        let commands = PDC002Commands(transport: device, settleNanoseconds: 0)
        let written = try await commands.configurePPS(
            selection: .highest, savedMillivolts: 5000, verify: true)
        XCTAssertEqual(written.raw, Self.traceBlockMax)
        let onDevice = await device.configContents
        XCTAssertEqual(onDevice, Self.traceBlockMax)
        let wasReset = await device.didReset
        XCTAssertFalse(wasReset)
    }
}

extension [UInt8] {
    init(hex: String) {
        self = stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }
}
