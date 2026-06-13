import Foundation
@testable import PDC002Kit

enum MockDeviceError: Error {
    case receiveOnEmptyQueue
    case writeWhileNotStarted
}

/// Simulates the PDC002 programmer's flash memory and report queue so the
/// command layer can be exercised without hardware.
actor MockDevice: FrameTransport {
    private var flash: Data
    /// The 52-byte PPS config page at 0xFC00, separate from the firmware
    /// region (0x2C00–0xFBFF) the `flash` buffer models.
    private var config: [UInt8]
    private var queue: [[UInt8]] = []
    private var writeSession = false
    private(set) var didReset = false

    init(flash: Data, config: [UInt8] = [UInt8](repeating: 0xFF, count: PPSConfig.size)) {
        precondition(flash.count == PDC002Commands.firmwareSize)
        precondition(config.count == PPSConfig.size)
        self.flash = flash
        self.config = config
    }

    var flashContents: Data { flash }
    var configContents: [UInt8] { config }

    func send(_ frame: [UInt8]) async throws {
        let payloadLen = frame[8] == Command.reset.rawValue ? 50 : Int(frame[9])
        let payload = Array(frame[10..<(10 + payloadLen)])
        switch Command(rawValue: frame[8]) {
        case .progMode:
            queue.append(ack())
        case .startWrite:
            writeSession = true
            queue.append(ack())
        case .endWrite:
            writeSession = false
            queue.append(ack())
        case .reset:
            didReset = true
            queue.append(ack())
        case .delete:
            guard writeSession else { throw MockDeviceError.writeWhileNotStarted }
            if payload[1] == PDC002Commands.ppsConfigHighByte {
                config = [UInt8](repeating: 0xFF, count: PPSConfig.size)
            } else {
                let offset = pageOffset(highByte: payload[1])
                flash.replaceSubrange(
                    offset..<(offset + PDC002Commands.pageSize),
                    with: Data(repeating: 0xFF, count: PDC002Commands.pageSize))
            }
        case .write:
            guard writeSession else { throw MockDeviceError.writeWhileNotStarted }
            let len = Int(payload[4])
            if payload[1] == PDC002Commands.ppsConfigHighByte {
                let offset = Int(payload[0])  // within the 0xFC00 page
                config.replaceSubrange(offset..<(offset + len), with: payload[5..<(5 + len)])
            } else {
                let offset = (Int(payload[1]) << 8 | Int(payload[0])) - PDC002Commands.firmwareBaseAddress
                flash.replaceSubrange(offset..<(offset + len), with: payload[5..<(5 + len)])
            }
        case .readBulk:
            let offset = pageOffset(highByte: payload[1])
            let page = flash.subdata(in: offset..<(offset + PDC002Commands.pageSize))
            for i in 0..<26 {
                let len = i < 25 ? 40 : 24
                var report = [UInt8](repeating: 0, count: 64)
                report.replaceSubrange(10..<(10 + len), with: page[(i * 40)..<(i * 40 + len)])
                queue.append(report)
            }
        case .readInfo:
            var report = [UInt8](repeating: 0, count: 64)
            if payload[1] == PDC002Commands.ppsConfigHighByte {
                report.replaceSubrange(10..<(10 + PPSConfig.size), with: config)
            } else {
                report.replaceSubrange(10..<25, with: Array("MOCK PPS NAME !".utf8))
            }
            queue.append(report)
        case .none:
            break
        }
    }

    func receive(timeout: TimeInterval) async throws -> [UInt8] {
        guard !queue.isEmpty else { throw MockDeviceError.receiveOnEmptyQueue }
        return queue.removeFirst()
    }

    func drainInput() async {
        queue.removeAll()
    }

    private func ack() -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 64)
        report[0] = 0xFF
        report[1] = 0x55
        report[8] = 2
        return report
    }

    private func pageOffset(highByte: UInt8) -> Int {
        (Int(highByte) << 8) - PDC002Commands.firmwareBaseAddress
    }
}
