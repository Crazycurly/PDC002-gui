import PDC002Kit
import SwiftUI

@main
struct PDC002App: App {
    @StateObject private var viewModel = FlasherViewModel()

    init() {
        // Hidden diagnostics: `open PDC002.app --args --selftest /tmp/out.log`
        // runs the identify flow headless inside the app's own launch
        // context and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            let logPath = args[i + 1]
            Task.detached { await runSelfTest(logPath: logPath) }
        }
        // `--selftest-flash <preset-id> <log>`: full flash + verify cycle.
        if let i = args.firstIndex(of: "--selftest-flash"), i + 2 < args.count {
            let presetID = args[i + 1]
            let logPath = args[i + 2]
            Task.detached { await runSelfTest(logPath: logPath, flashPresetID: presetID) }
        }
    }

    var body: some Scene {
        WindowGroup("PDC002 Flasher") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 560, minHeight: 320)
        }
        .defaultSize(width: 780, height: 439)
    }
}

private func runSelfTest(logPath: String, flashPresetID: String? = nil) async {
    let lines = LineBuffer(path: logPath)
    let log: @Sendable (String) -> Void = { lines.append($0) }

    log("selftest pid \(getpid())")
    log("input monitoring: \(PDC002DeviceManager.inputMonitoringAccess())")
    let manager = PDC002DeviceManager()
    var transport: HIDTransport?
    for _ in 0..<50 {
        if let t = manager.transport {
            transport = t
            break
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let opens = manager.openStatuses
    log(String(
        format: "managerOpen=0x%08X deviceOpen=0x%08X",
        opens.manager ?? -1, opens.device ?? -1))
    guard let transport else {
        log("FAIL: no transport (device not matched)")
        exit(2)
    }

    let commands = PDC002Commands(transport: transport)
    do {
        if let flashPresetID {
            guard let preset = FirmwareCatalog.preset(id: flashPresetID) else {
                log("FAIL: unknown preset \(flashPresetID)")
                exit(2)
            }
            let firmware = try FirmwareCatalog.load(preset)
            log("flashing \(preset.name) via flash() — verify on")
            let t = Date()
            let now: @Sendable () -> String = { String(format: "%6.3f", Date().timeIntervalSince(t)) }
            // Exercises the exact code path the GUI's Flash button uses.
            try await commands.flash(body: firmware.body, verify: true) { phase, value in
                if value == 0 || value == 1 {
                    log(String(format: "  [%@] %@ %.0f%%", now(), phase.rawValue, value * 100))
                }
            }
            log("  [\(now())] flash + verify PASS")
            lines.flush()
            exit(0)
        }
        try await commands.progMode()
        log("progMode OK")
        log("ppsName: \(try await commands.readPpsName())")
        let started = Date()
        let body = try await commands.readFirmware()
        log(String(format: "read %d bytes in %.2f s", body.count, -started.timeIntervalSinceNow))
        log("identified: \(FirmwareCatalog.identify(body: body)?.name ?? "unknown")")
        try await commands.reset()
        log("reset OK")
        log("PASS")
        lines.flush()
        exit(0)
    } catch {
        log("FAIL: \(error)")
        lines.flush()
        exit(1)
    }
}

/// Buffers diagnostic lines in memory and writes them to disk only on
/// explicit flush, so logging never delays HID traffic mid-sequence.
private final class LineBuffer: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var lines: [String] = []

    init(path: String) { self.path = path }

    func append(_ s: String) {
        lock.lock()
        lines.append(s)
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let text = lines.joined(separator: "\n")
        lock.unlock()
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
