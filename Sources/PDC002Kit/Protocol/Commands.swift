import Foundation

/// Sends 64-byte frames to the programmer and yields its 64-byte input
/// reports. `receive(timeout:)` blocks until a report arrives, throwing
/// `HIDError.receiveTimeout` after `timeout` seconds.
public protocol FrameTransport: Sendable {
    func send(_ frame: [UInt8]) async throws
    func receive(timeout: TimeInterval) async throws -> [UInt8]
    /// Discard any queued input reports so the next receive() pairs with
    /// the next request (delete/write commands are sent without reading
    /// responses, so stale reports may be pending).
    func drainInput() async
}

public enum FlashError: Error, LocalizedError {
    case verifyFailed
    case shortResponse

    public var errorDescription: String? {
        switch self {
        case .verifyFailed:
            return "Verification failed: read-back does not match the written firmware. Do not unplug; try flashing again."
        case .shortResponse:
            return "Device returned a truncated report."
        }
    }
}

public enum FlashPhase: String, Sendable {
    case erase = "Erasing"
    case write = "Writing"
    case verify = "Verifying"
    case reset = "Resetting"
}

/// High-level PDC002 operations, mirroring the reverse-engineered protocol
/// in reference/PDC002/pdc002.py.
public struct PDC002Commands: Sendable {
    /// Firmware occupies 16-bit flash addresses 0x2C00...0xF8FF: 52 pages
    /// of 1 KB, written as 25 chunks of 40 bytes + 1 chunk of 24 bytes per
    /// page (chunks never cross a page boundary).
    public static let firmwareBaseAddress = 0x2C00
    public static let pageCount = 52
    public static let pageSize = 1024
    public static let chunkSize = 40
    public static let firmwareSize = pageCount * pageSize  // 53,248

    /// The "online" firmware keeps its PC-configurable PPS settings in a
    /// 52-byte block at flash 0xFC00 (high address byte 0xFC), one page above
    /// the firmware region.
    public static let ppsConfigAddress = 0xFC00
    public static let ppsConfigHighByte: UInt8 = 0xFC

    private let transport: any FrameTransport
    private let clock: FrameClock
    /// Delay between sending a command and reading its response, mirroring
    /// the reference tool's `time.sleep(0.08)`. This is not cosmetic: the
    /// device silently ignores a write-session command (startWrite/endWrite)
    /// that arrives too soon after the previous one. Injectable so tests
    /// run instantly.
    private let settle: UInt64

    public init(
        transport: any FrameTransport,
        clock: FrameClock = FrameClock(),
        settleNanoseconds: UInt64 = 80_000_000
    ) {
        self.transport = transport
        self.clock = clock
        self.settle = settleNanoseconds
    }

    // MARK: - Primitive commands

    private func frame(_ command: Command, _ payload: [UInt8]) -> [UInt8] {
        Frame.build(command: command.rawValue, payload: payload, timestamp: clock.timestamp())
    }

    /// Send a command and read its single ack. The device ignores a
    /// write-session command that arrives before it has finished digesting
    /// the previous one, so the settle is taken BEFORE sending (giving the
    /// device time to become ready) and a still-missing ack is retried with
    /// a growing settle. These commands — prog mode, start/end write, info —
    /// are idempotent, so re-sending is safe.
    @discardableResult
    private func request(_ command: Command, _ payload: [UInt8] = []) async throws -> [UInt8] {
        var lastError: Error = FlashError.shortResponse
        for attempt in 0..<8 {
            await transport.drainInput()
            if settle > 0 { try await Task.sleep(nanoseconds: settle * UInt64(attempt + 1)) }
            try await transport.send(frame(command, payload))
            do {
                // The ack arrives within a few ms when the device accepts
                // the command; a short window keeps retries quick.
                return try await transport.receive(timeout: 0.3)
            } catch HIDError.receiveTimeout {
                lastError = HIDError.receiveTimeout
            }
        }
        throw lastError
    }

    private func sendOnly(_ command: Command, _ payload: [UInt8]) async throws {
        try await transport.send(frame(command, payload))
    }

    public func progMode() async throws { try await request(.progMode) }
    public func startWrite() async throws { try await request(.startWrite) }
    public func endWrite() async throws { try await request(.endWrite) }

    public func reset() async throws {
        // Fixed magic payload captured from the official tool; the device
        // reboots into the flashed firmware.
        let payload: [UInt8] = [
            133, 4, 239, 56, 210, 118, 176, 156, 34, 1, 0, 0, 0, 0, 24, 49,
            225, 0, 0, 0, 0, 0, 176, 242, 118, 0, 192, 3, 59, 117, 255, 255,
            255, 255, 176, 242, 118, 0, 151, 50, 221, 0, 226, 4, 5, 0, 128,
            1, 0, 0,
        ]
        await transport.drainInput()
        if settle > 0 { try await Task.sleep(nanoseconds: settle) }
        try await sendOnly(.reset, payload)
        // The device may drop off USB to reboot before acking.
        _ = try? await transport.receive(timeout: 0.6)
    }

    public func delete() async throws {
        for addr in Self.pageAddresses() {
            try await sendOnly(.delete, [0, addr, 0, 8])
            // The official tool spaces deletes ~17 ms apart (per the 9V
            // capture), giving the device time to erase each page.
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    public func write(body: Data, progress: @Sendable (Double) -> Void = { _ in }) async throws {
        let chunks = Self.writeChunks(for: body)
        for (i, chunk) in chunks.enumerated() {
            var payload: [UInt8] = [chunk.addr0, chunk.addr1, 0, 8, UInt8(chunk.data.count)]
            payload.append(contentsOf: chunk.data)
            try await sendOnly(.write, payload)
            // Report sparsely: there are ~1,352 chunks, and a progress
            // callback per chunk floods the UI thread.
            if i % 16 == 0 || i == chunks.count - 1 {
                progress(Double(i + 1) / Double(chunks.count))
            }
        }
    }

    public func readFirmware(progress: @Sendable (Double) -> Void = { _ in }) async throws -> Data {
        var firmware = Data(capacity: Self.firmwareSize)
        let addrs = Self.pageAddresses()
        for (i, addr) in addrs.enumerated() {
            firmware.append(try await readPage(addr: addr))
            progress(Double(i + 1) / Double(addrs.count))
        }
        return firmware
    }

    /// Read one 1 KB page (26 reports). Reading is idempotent, so a page
    /// whose report burst was interrupted is simply requested again.
    private func readPage(addr: UInt8) async throws -> Data {
        var lastError: Error = FlashError.shortResponse
        for _ in 0..<3 {
            await transport.drainInput()
            try await sendOnly(.readBulk, [0, addr, 0, 8, 0, 4])
            do {
                var page = Data(capacity: Self.pageSize)
                for report in 0..<26 {
                    let msg = try await transport.receive(timeout: 2.0)
                    guard msg.count >= 50 else { throw FlashError.shortResponse }
                    page.append(contentsOf: report < 25 ? msg[10..<50] : msg[10..<34])
                }
                return page
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    public func readPpsName() async throws -> String {
        let msg = try await request(.readInfo, [0, 56, 0, 8, 15])
        guard msg.count >= 25 else { throw FlashError.shortResponse }
        return String(bytes: msg[10..<25], encoding: .ascii) ?? ""
    }

    // MARK: - PPS configuration (online firmware)

    /// Read the 52-byte PPS configuration block at 0xFC00 (the "读线" / read
    /// line operation): the recorded charger PDO list, the selected request
    /// mode, and the saved target voltage. The whole block fits in one input
    /// report's payload. Mirrors `readPpsModes` in the reference tool.
    public func readPPSConfig() async throws -> PPSConfig {
        let high = Self.ppsConfigHighByte
        let msg = try await request(.readInfo, [0, high, 0, 8, UInt8(PPSConfig.size)])
        guard msg.count >= 10 + PPSConfig.size else { throw FlashError.shortResponse }
        return try PPSConfig(block: Array(msg[10..<(10 + PPSConfig.size)]))
    }

    /// Write a 52-byte config block back to 0xFC00 (the "写线" / write line
    /// operation). The official tool erases the single config page, then
    /// writes a 40-byte chunk followed by a 12-byte chunk, all inside one
    /// startWrite/endWrite session (see traces/pps-config.txt). No reset is
    /// sent — the cable adopts the new config on its next attach.
    public func writePPSConfig(_ block: [UInt8]) async throws {
        precondition(block.count == PPSConfig.size)
        let high = Self.ppsConfigHighByte
        try await startWrite()
        try await sendOnly(.delete, [0, high, 0, 8])
        // Give the page erase time to settle, like the inter-page delete delay.
        try await Task.sleep(nanoseconds: 15_000_000)
        try await sendOnly(.write, [0, high, 0, 8, 40] + block[0..<40])
        try await sendOnly(.write, [40, high, 0, 8, 12] + block[40..<52])
        try await endWrite()
    }

    /// Reconfigure the cable's PPS request: enter prog mode, read the current
    /// block (needed to preserve the recorded PDO list and re-derive the
    /// checksum), apply the new selection/voltage, write it back, and
    /// optionally re-read to verify before returning. Returns the written
    /// config.
    @discardableResult
    public func configurePPS(
        selection: PPSSelection,
        savedMillivolts: Int,
        verify: Bool = true
    ) async throws -> PPSConfig {
        try await progMode()
        let current = try await readPPSConfig()
        let updated = current.updating(selection: selection, savedMillivolts: savedMillivolts)
        try await writePPSConfig(updated.raw)
        if verify {
            // A single read can occasionally misassemble under load (as in
            // flash()'s verify); since the block is already written, re-read
            // from a fresh prog session and only fail on a persistent mismatch.
            var matched = false
            for _ in 0..<3 {
                try await progMode()
                if try await readPPSConfig() == updated { matched = true; break }
            }
            guard matched else { throw FlashError.verifyFailed }
        }
        return updated
    }

    // MARK: - Flash orchestration

    /// Full flash sequence: prog mode, erase, write, optional read-back
    /// verification, then reset. Verification re-enters prog mode before
    /// reading (a read taken in the just-closed write session returns stale
    /// data) and runs before reset, so a verify failure leaves the device
    /// in prog mode rather than rebooted into a bad image.
    public func flash(
        body: Data,
        verify: Bool,
        progress: @escaping @Sendable (FlashPhase, Double) -> Void = { _, _ in }
    ) async throws {
        try await progMode()

        progress(.erase, 0)
        try await startWrite()
        try await delete()
        try await endWrite()
        progress(.erase, 1)

        try await startWrite()
        try await write(body: body) { progress(.write, $0) }
        try await endWrite()

        if verify {
            progress(.verify, 0)
            var matched = false
            // A read can occasionally misassemble under load; since the
            // firmware is already written, re-reading from a fresh prog-mode
            // session resolves a transient mismatch. Only a persistent
            // mismatch means the write actually failed.
            for _ in 0..<3 {
                try await progMode()
                let readBack = try await readFirmware { progress(.verify, $0) }
                if readBack == body {
                    matched = true
                    break
                }
            }
            guard matched else { throw FlashError.verifyFailed }
        }

        if settle > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        progress(.reset, 0)
        try await reset()
        progress(.reset, 1)
    }

    // MARK: - Address math

    /// High address bytes of the 52 firmware pages: 0x2C, 0x30, ... 0xF8.
    public static func pageAddresses() -> [UInt8] {
        stride(from: 0x2C, through: 0xF8, by: 4).map { UInt8($0) }
    }

    public struct WriteChunk: Equatable, Sendable {
        public let addr0: UInt8
        public let addr1: UInt8
        public let data: Data
    }

    /// Split a firmware body into page-aligned write chunks with their
    /// little-endian-split flash addresses (base 0x2C00).
    public static func writeChunks(for body: Data) -> [WriteChunk] {
        var chunks: [WriteChunk] = []
        var offset = 0
        while offset < body.count {
            let pageEnd = min(((offset / pageSize) + 1) * pageSize, body.count)
            let len = min(chunkSize, pageEnd - offset)
            let address = firmwareBaseAddress + offset
            chunks.append(WriteChunk(
                addr0: UInt8(address & 0xFF),
                addr1: UInt8((address >> 8) & 0xFF),
                data: body.subdata(in: offset..<(offset + len))
            ))
            offset += len
        }
        return chunks
    }
}
