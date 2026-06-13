import XCTest
@testable import PDC002Kit

/// End-to-end tests against a physically connected PDC002 programmer.
/// Skipped unless PDC002_HW=1 (they talk to real hardware). Read-only:
/// enters prog mode, reads all 52 pages, identifies the firmware, then
/// resets the device back to normal operation.
final class RealDeviceTests: XCTestCase {
    func testIdentifyAndResetOnRealDevice() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PDC002_HW"] == "1",
            "set PDC002_HW=1 with a PDC002 plugged in to run")

        let manager = PDC002DeviceManager()
        var transport: HIDTransport?
        for _ in 0..<50 {  // up to 5 s for matching
            if let t = manager.transport {
                transport = t
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let hid = try XCTUnwrap(transport, "no PDC002 programmer found")

        let commands = PDC002Commands(transport: hid)
        try await commands.progMode()

        let name = try await commands.readPpsName()
        print("readPpsName: \(name)")

        let started = Date()
        let body = try await commands.readFirmware()
        print("read 52 KB in \(String(format: "%.2f", -started.timeIntervalSinceNow)) s")
        XCTAssertEqual(body.count, PD1S.expectedBodySize)

        let preset = FirmwareCatalog.identify(body: body)
        print("identified: \(preset?.name ?? "unknown firmware")")

        try await commands.reset()
    }

    /// Read-only PPS "读线": dumps the recorded PDO list and current
    /// selection so the decode can be eyeballed against the attached charger.
    /// Does not write — only enters prog mode and reads 0xFC00.
    func testReadPPSConfigOnRealDevice() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PDC002_HW"] == "1",
            "set PDC002_HW=1 with a PDC002 plugged in to run")

        let manager = PDC002DeviceManager()
        var transport: HIDTransport?
        for _ in 0..<50 {
            if let t = manager.transport { transport = t; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let hid = try XCTUnwrap(transport, "no PDC002 programmer found")
        let commands = PDC002Commands(transport: hid)

        try await commands.progMode()
        let config = try await commands.readPPSConfig()
        print("raw: \(config.raw)")
        print("erased: \(config.isErased)  selection: \(config.selection)  saved: \(config.savedMillivolts) mV  PD\(config.pdVersion ?? 0)")
        for (i, pdo) in config.pdos.enumerated() { print("PDO \(i + 1): \(pdo)") }

        try await commands.reset()
    }

    /// PPS "写线": writes an arbitrary PPS voltage (9.00 V) and verifies the
    /// read-back. Mutates the cable's config, so it needs PDC002_HW_WRITE=1 on
    /// top of PDC002_HW=1 to avoid rewriting the cable on a normal hardware run.
    /// The recorded PDO list is preserved; no firmware is touched.
    func testConfigureArbitraryVoltageOnRealDevice() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PDC002_HW"] == "1"
                && ProcessInfo.processInfo.environment["PDC002_HW_WRITE"] == "1",
            "set PDC002_HW=1 PDC002_HW_WRITE=1 with a PDC002 on a PPS charger to run")

        let manager = PDC002DeviceManager()
        var transport: HIDTransport?
        for _ in 0..<50 {
            if let t = manager.transport { transport = t; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let hid = try XCTUnwrap(transport, "no PDC002 programmer found")
        let commands = PDC002Commands(transport: hid)

        let written = try await commands.configurePPS(
            selection: .arbitrary, savedMillivolts: 9000, verify: true)
        print("wrote: selection \(written.selection)  saved \(written.savedMillivolts) mV")
        XCTAssertEqual(written.selection, .arbitrary)
        XCTAssertEqual(written.savedMillivolts, 9000)

        // Re-read from a fresh prog session to confirm it stuck.
        try await commands.progMode()
        let readBack = try await commands.readPPSConfig()
        print("read back: selection \(readBack.selection)  saved \(readBack.savedMillivolts) mV  PDOs \(readBack.pdos.count)")
        XCTAssertEqual(readBack.raw, written.raw)
        XCTAssertEqual(readBack.savedMillivolts, 9000)
        XCTAssertFalse(readBack.pdos.isEmpty, "PDO list must be preserved")

        try await commands.reset()
    }

    /// Isolates the erase handshake: progMode → startWrite → endWrite. No
    /// actual erase payload, so the firmware is left intact.
    func testStartWriteHandshakeOnRealDevice() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PDC002_HW"] == "1",
            "set PDC002_HW=1 with a PDC002 plugged in to run")

        let manager = PDC002DeviceManager()
        var transport: HIDTransport?
        for _ in 0..<50 {
            if let t = manager.transport { transport = t; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let hid = try XCTUnwrap(transport, "no PDC002 programmer found")
        let commands = PDC002Commands(transport: hid)

        let t = Date()
        func el() -> String { String(format: "%.3f", Date().timeIntervalSince(t)) }
        try await commands.progMode(); print("[\(el())] progMode OK")
        try await commands.startWrite(); print("[\(el())] startWrite OK")
        try await commands.endWrite(); print("[\(el())] endWrite OK")
        try await commands.reset(); print("[\(el())] reset OK")
    }
}
