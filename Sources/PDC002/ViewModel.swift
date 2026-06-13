import Combine
import Foundation
import PDC002Kit

struct LoadedFirmware: Equatable {
    let name: String
    let source: String
    let presetID: String?
    let firmware: Firmware
}

@MainActor
final class FlasherViewModel: ObservableObject {
    enum Operation: String {
        case identify = "Reading device"
        case flash = "Flashing"
        case reset = "Resetting"
        case readLine = "Reading line"
        case writeLine = "Writing line"
    }

    let deviceManager = PDC002DeviceManager()

    @Published var selectedPresetID: String?
    @Published private(set) var loadedFirmware: LoadedFirmware?
    @Published var verifyAfterFlash = true

    @Published private(set) var currentOperation: Operation?
    @Published private(set) var phaseDescription = ""
    @Published private(set) var progress: Double?
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?

    /// Name of the firmware identified on the device; nil = not read yet.
    @Published private(set) var deviceFirmwareName: String?

    /// Last-read PPS config block ("读线"); nil until Read Line is pressed.
    @Published private(set) var ppsConfig: PPSConfig?
    /// Which voltage the cable should request, edited in the UI.
    @Published var ppsSelection: PPSSelection = .highest {
        didSet { clampTargetToSelection() }
    }
    /// Target voltage (volts) used when a PPS/variable PDO is selected.
    @Published var ppsTargetVolts: Double = 5.0
    /// After a flash the device resets and re-enumerates; this carries the
    /// just-flashed name across the reconnect so the status reflects it.
    private var firmwareNameToRestoreOnReconnect: String?

    private var cancellables: Set<AnyCancellable> = []

    var deviceConnected: Bool { deviceManager.deviceName != nil }
    var busy: Bool { currentOperation != nil }

    init() {
        deviceManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        deviceManager.$deviceName
            .receive(on: DispatchQueue.main)
            .sink { [weak self] name in
                guard let self else { return }
                if name == nil {
                    self.deviceFirmwareName = nil
                } else if let restored = self.firmwareNameToRestoreOnReconnect {
                    // Device came back after a flash-induced reset.
                    self.deviceFirmwareName = restored
                    self.firmwareNameToRestoreOnReconnect = nil
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Firmware selection

    func selectPreset(_ preset: FirmwarePreset) {
        do {
            let firmware = try FirmwareCatalog.load(preset)
            selectedPresetID = preset.id
            loadedFirmware = LoadedFirmware(
                name: preset.name,
                source: "Bundled preset",
                presetID: preset.id,
                firmware: firmware)
        } catch {
            errorMessage = "Could not load bundled preset: \(error.localizedDescription)"
        }
    }

    func openCustomFile(_ url: URL) {
        do {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let firmware = try PD1S.decode(Data(contentsOf: url))
            let presetID = FirmwareCatalog.identify(body: firmware.body)?.id
            selectedPresetID = nil
            loadedFirmware = LoadedFirmware(
                name: url.lastPathComponent,
                source: url.path,
                presetID: presetID,
                firmware: firmware)
        } catch {
            errorMessage = "Not a valid .pd1s file: \(error.localizedDescription)"
        }
    }

    // MARK: - Device operations

    func identify() {
        run(.identify) { commands in
            try await commands.progMode()
            let body = try await commands.readFirmware { value in
                Task { @MainActor in
                    self.updateProgress(phase: Operation.identify.rawValue, value: value)
                }
            }
            let preset = FirmwareCatalog.identify(body: body)
            await MainActor.run {
                self.deviceFirmwareName = preset?.name ?? "Unknown firmware"
                self.statusMessage = preset.map { "Device firmware: \($0.name)" }
                    ?? "Device firmware does not match any bundled preset."
            }
        }
    }

    func flash() {
        guard let loaded = loadedFirmware else { return }
        let verify = verifyAfterFlash
        run(.flash) { commands in
            try await commands.flash(body: loaded.firmware.body, verify: verify) { phase, value in
                Task { @MainActor in
                    self.updateProgress(phase: phase.rawValue, value: value)
                }
            }
            await MainActor.run {
                self.deviceFirmwareName = loaded.name
                self.firmwareNameToRestoreOnReconnect = loaded.name
                self.statusMessage = verify
                    ? "Flashed \(loaded.name) — verification passed."
                    : "Flashed \(loaded.name)."
            }
        }
    }

    func resetDevice() {
        run(.reset) { commands in
            try await commands.reset()
            await MainActor.run { self.statusMessage = "Reset command sent." }
        }
    }

    // MARK: - PPS arbitrary voltage (online firmware)

    /// "读线": read the cable's recorded PDO list and current selection.
    func readPPSLine() {
        run(.readLine) { commands in
            try await commands.progMode()
            let config = try await commands.readPPSConfig()
            await MainActor.run {
                self.ppsConfig = config
                self.syncSelectionFromConfig(config)
                self.statusMessage = config.isErased
                    ? "No PDO list on the cable. Plug it into a PD charger first, then read again (needs the Online/PC-config firmware)."
                    : "Read line: \(config.pdos.count) PDO(s), \(Self.describe(config.selection)) selected."
            }
        }
    }

    /// "写线": write the chosen request mode / target voltage back to the cable.
    func writePPSLine() {
        guard let config = ppsConfig, !config.isErased else { return }
        let selection = ppsSelection
        let millivolts = resolvedSavedMillivolts(for: selection, config: config)
        run(.writeLine) { commands in
            let written = try await commands.configurePPS(
                selection: selection, savedMillivolts: millivolts, verify: true)
            await MainActor.run {
                self.ppsConfig = written
                let voltageNote = selection.carriesTargetVoltage
                    ? String(format: " @ %.2f V", Double(millivolts) / 1000)
                    : ""
                self.statusMessage =
                    "Wrote line: \(Self.describe(selection))\(voltageNote) — verified."
            }
        }
    }

    /// Whether Write Line should be enabled for the current state.
    var canWritePPSLine: Bool {
        guard deviceConnected, !busy, let config = ppsConfig, !config.isErased else { return false }
        switch ppsSelection {
        case .arbitrary: return config.ppsRange != nil
        case .pdo(let index): return config.pdos.indices.contains(index)
        case .lowest, .highest, .rotate: return true
        }
    }

    static func describe(_ selection: PPSSelection) -> String {
        switch selection {
        case .lowest: return "Lowest"
        case .highest: return "Highest"
        case .rotate: return "Rotate"
        case .arbitrary: return "PPS arbitrary"
        case .pdo(let index): return "PDO \(index + 1)"
        }
    }

    /// Resolve the saved-voltage field for a write: arbitrary PPS uses the
    /// slider value (clamped to the PPS window, snapped to 20 mV steps), a
    /// fixed PDO its own voltage, and min/max/rotate keep what was saved.
    private func resolvedSavedMillivolts(for selection: PPSSelection, config: PPSConfig) -> Int {
        switch selection {
        case .arbitrary:
            return snappedTarget(in: config.ppsRange)
        case .pdo(let index) where config.pdos.indices.contains(index):
            switch config.pdos[index] {
            case .fixed(let millivolts, _):
                return millivolts
            case .pps(let low, let high, _):
                return snappedTarget(in: (low, high))
            }
        default:
            return config.savedMillivolts
        }
    }

    /// The slider voltage in millivolts, clamped to `range` and snapped to a
    /// 20 mV (PPS) step.
    private func snappedTarget(in range: (minMillivolts: Int, maxMillivolts: Int)?) -> Int {
        let target = Int((ppsTargetVolts * 1000).rounded())
        let clamped = range.map { min(max(target, $0.minMillivolts), $0.maxMillivolts) } ?? target
        return clamped / 20 * 20
    }

    private func syncSelectionFromConfig(_ config: PPSConfig) {
        if config.isErased {
            ppsSelection = .highest
        } else if case .pdo(let index) = config.selection, !config.pdos.indices.contains(index) {
            // An out-of-range PDO byte we don't model: fall back to a safe mode.
            ppsSelection = config.ppsRange != nil ? .arbitrary : .highest
        } else {
            ppsSelection = config.selection
        }
        if (1...59_000).contains(config.savedMillivolts) {
            ppsTargetVolts = Double(config.savedMillivolts) / 1000
        }
    }

    /// Keep the target slider value inside the active PPS window.
    private func clampTargetToSelection() {
        let range: (minMillivolts: Int, maxMillivolts: Int)?
        switch ppsSelection {
        case .arbitrary:
            range = ppsConfig?.ppsRange
        case .pdo(let index):
            if let config = ppsConfig, config.pdos.indices.contains(index),
               case .pps(let low, let high, _) = config.pdos[index] {
                range = (low, high)
            } else {
                range = nil
            }
        default:
            range = nil
        }
        guard let range else { return }
        ppsTargetVolts = min(
            max(ppsTargetVolts, Double(range.minMillivolts) / 1000),
            Double(range.maxMillivolts) / 1000)
    }

    private func run(
        _ operation: Operation,
        _ work: @escaping @Sendable (PDC002Commands) async throws -> Void
    ) {
        guard !busy else { return }
        guard let transport = deviceManager.transport else {
            errorMessage = "No PDC002 programmer connected."
            return
        }
        currentOperation = operation
        phaseDescription = operation.rawValue
        progress = nil
        statusMessage = nil
        errorMessage = nil
        let commands = PDC002Commands(transport: transport)
        Task {
            do {
                try await work(commands)
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.currentOperation = nil
            self.progress = nil
            self.phaseDescription = ""
        }
    }

    /// Throttles published progress so per-chunk callbacks (1,352 during a
    /// write) don't trigger a SwiftUI render each.
    private func updateProgress(phase: String, value: Double) {
        if phaseDescription != phase {
            phaseDescription = phase
            progress = value
            return
        }
        if let current = progress, value < 1, value - current < 0.01 { return }
        progress = value
    }
}
