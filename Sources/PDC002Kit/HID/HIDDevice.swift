import Foundation
import IOKit.hid

public struct HIDLogEvent: Sendable {
    public enum Direction: String, Sendable {
        case tx = "TX"
        case rx = "RX"
    }

    public let direction: Direction
    public let bytes: [UInt8]
}

public enum HIDError: Error, LocalizedError {
    case deviceDisconnected
    case sendFailed(IOReturn)
    case receiveTimeout

    public var errorDescription: String? {
        switch self {
        case .deviceDisconnected:
            return "The PDC002 programmer is not connected."
        case .sendFailed(let code):
            return String(format: "Sending to the device failed (IOKit error 0x%08X).", code)
        case .receiveTimeout:
            return "The device did not respond in time."
        }
    }
}

/// FrameTransport over one opened IOHIDDevice. Input reports are buffered
/// as they arrive on the main run loop; receive() polls the buffer so no
/// continuation bookkeeping is needed.
public final class HIDTransport: FrameTransport, @unchecked Sendable {
    private let device: IOHIDDevice
    private let lock = NSLock()
    private var reports: [[UInt8]] = []
    private var valid = true
    /// Some HID stacks expect the report ID parameter to mirror the first
    /// buffer byte (hidapi behavior for numbered reports). Start with
    /// report ID 0 and fall back once if the device rejects it.
    private var useFirstByteAsReportID = false
    /// Must outlive the input-report callback registration.
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputBufferSize = 256

    public var logHandler: (@Sendable (HIDLogEvent) -> Void)?

    /// PDC002_HIDDEBUG=1 prints every send/receive with a hex dump.
    private static let debug = ProcessInfo.processInfo.environment["PDC002_HIDDEBUG"] == "1"
    private static let debugStart = Date()
    private static func dbg(_ dir: String, _ bytes: [UInt8], _ extra: String = "") {
        guard debug else { return }
        let t = String(format: "%7.3f", Date().timeIntervalSince(debugStart))
        let hex = bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
        FileHandle.standardError.write(Data("[\(t)] \(dir) \(hex)… \(extra)\n".utf8))
    }

    init(device: IOHIDDevice) {
        self.device = device
        inputBuffer = .allocate(capacity: inputBufferSize)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, inputBufferSize,
            { context, result, _, _, _, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                let transport = Unmanaged<HIDTransport>.fromOpaque(context).takeUnretainedValue()
                transport.handleInput(Array(UnsafeBufferPointer(start: report, count: reportLength)))
            },
            context)
    }

    deinit {
        inputBuffer.deallocate()
    }

    func invalidate() {
        lock.lock()
        valid = false
        reports.removeAll()
        lock.unlock()
    }

    private func handleInput(_ bytes: [UInt8]) {
        Self.dbg("IN ", bytes)
        lock.lock()
        if valid { reports.append(bytes) }
        lock.unlock()
        logHandler?(HIDLogEvent(direction: .rx, bytes: bytes))
    }

    public func send(_ frame: [UInt8]) async throws {
        try performSend(frame)
    }

    private func performSend(_ frame: [UInt8]) throws {
        lock.lock()
        let isValid = valid
        let firstByteID = useFirstByteAsReportID
        lock.unlock()
        guard isValid else { throw HIDError.deviceDisconnected }

        var result = setReport(frame, reportID: firstByteID ? CFIndex(frame[0]) : 0)
        if result != kIOReturnSuccess, !firstByteID {
            result = setReport(frame, reportID: CFIndex(frame[0]))
            if result == kIOReturnSuccess {
                lock.lock()
                useFirstByteAsReportID = true
                lock.unlock()
            }
        }
        guard result == kIOReturnSuccess else { throw HIDError.sendFailed(result) }
        Self.dbg("OUT", frame, "cmd=\(frame[8]) plen=\(frame[9]) r=0x\(String(result, radix: 16)) id=\(firstByteID ? frame[0] : 0)")
        logHandler?(HIDLogEvent(direction: .tx, bytes: frame))
    }

    private func setReport(_ frame: [UInt8], reportID: CFIndex) -> IOReturn {
        frame.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, reportID, $0.baseAddress!, $0.count)
        }
    }

    private enum PopResult {
        case report([UInt8])
        case empty
        case invalid
    }

    private func popReport() -> PopResult {
        lock.lock()
        defer { lock.unlock() }
        guard valid else { return .invalid }
        guard !reports.isEmpty else { return .empty }
        return .report(reports.removeFirst())
    }

    public func receive(timeout: TimeInterval) async throws -> [UInt8] {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while true {
            switch popReport() {
            case .report(let report):
                return report
            case .invalid:
                throw HIDError.deviceDisconnected
            case .empty:
                guard Date() < deadline else { throw HIDError.receiveTimeout }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    public func drainInput() async {
        clearReports()
    }

    private func clearReports() {
        lock.lock()
        reports.removeAll()
        lock.unlock()
    }
}

/// Watches for the PDC002 programmer (VID 0x0716, PID 0x5036) coming and
/// going and exposes a transport for the connected device.
///
/// All IOKit work runs on a dedicated thread with its own run loop so that
/// bursts of input reports (1,352 during a firmware read) are never starved
/// or dropped while the main thread is busy rendering UI.
public final class PDC002DeviceManager: ObservableObject, @unchecked Sendable {
    public static let vendorID = 0x0716
    public static let productID = 0x5036

    /// "Manufacturer Product" of the connected programmer; nil when absent.
    /// Always published on the main thread.
    @Published public private(set) var deviceName: String?

    private let lock = NSLock()
    private var _transport: HIDTransport?
    private var _logHandler: (@Sendable (HIDLogEvent) -> Void)?
    private var _managerOpenStatus: IOReturn?
    private var _deviceOpenStatus: IOReturn?

    /// IOReturn of IOHIDManagerOpen / IOHIDDeviceOpen, for diagnostics
    /// (0xE00002E2 = kIOReturnNotPermitted means TCC denied HID access).
    public var openStatuses: (manager: IOReturn?, device: IOReturn?) {
        lock.lock()
        defer { lock.unlock() }
        return (_managerOpenStatus, _deviceOpenStatus)
    }

    /// Whether macOS grants this process HID input monitoring.
    public static func inputMonitoringAccess() -> String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "undetermined"
        }
    }

    /// Ask macOS for HID input monitoring access (shows the system prompt
    /// when undetermined). Returns true if granted.
    @discardableResult
    public static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    public var transport: HIDTransport? {
        lock.lock()
        defer { lock.unlock() }
        return _transport
    }

    public var logHandler: (@Sendable (HIDLogEvent) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _logHandler
        }
        set {
            lock.lock()
            _logHandler = newValue
            _transport?.logHandler = newValue
            lock.unlock()
        }
    }

    /// Touched only on the HID thread.
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    public init() {
        let thread = Thread { [weak self] in
            self?.setUpManager()
            CFRunLoopRun()
        }
        thread.name = "PDC002.HID"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func setUpManager() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID] as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<PDC002DeviceManager>.fromOpaque(context)
                    .takeUnretainedValue().deviceMatched(device)
            },
            context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<PDC002DeviceManager>.fromOpaque(context)
                    .takeUnretainedValue().deviceRemoved(device)
            },
            context)

        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        lock.lock()
        _managerOpenStatus = status
        lock.unlock()
    }

    private func deviceMatched(_ matched: IOHIDDevice) {
        guard device == nil else { return }
        let status = IOHIDDeviceOpen(matched, IOOptionBits(kIOHIDOptionsTypeNone))
        device = matched

        let newTransport = HIDTransport(device: matched)
        lock.lock()
        _deviceOpenStatus = status
        newTransport.logHandler = _logHandler
        _transport = newTransport
        lock.unlock()

        let manufacturer =
            IOHIDDeviceGetProperty(matched, kIOHIDManufacturerKey as CFString) as? String ?? ""
        let product =
            IOHIDDeviceGetProperty(matched, kIOHIDProductKey as CFString) as? String ?? "PDC002"
        let name = [manufacturer, product]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        DispatchQueue.main.async { self.deviceName = name }
    }

    private func deviceRemoved(_ removed: IOHIDDevice) {
        guard removed == device else { return }
        device = nil
        lock.lock()
        _transport?.invalidate()
        _transport = nil
        lock.unlock()
        DispatchQueue.main.async { self.deviceName = nil }
    }
}
