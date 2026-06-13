import PDC002Kit
import SwiftUI

/// "PPS Arbitrary Voltage" panel: Read Line ("读线") to pull the cable's
/// recorded PDO list and current selection, pick a request mode / target
/// voltage, then Write Line ("写线") to store it. Only meaningful with the
/// Online (PC-configurable) firmware flashed and after the cable has been
/// plugged into a PD charger to record its PDOs.
struct PPSPanel: View {
    @ObservedObject var viewModel: FlasherViewModel
    @State private var showWriteConfirmation = false

    var body: some View {
        GroupBox("PPS Arbitrary Voltage") {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let config = viewModel.ppsConfig {
                    if config.isErased {
                        Text("No PDO list recorded. Plug the cable into a PD charger, then Read Line. Requires the Online (PC-configurable) firmware.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        configEditor(config)
                    }
                } else {
                    Text("Read Line to load the cable's recorded PDOs and current selection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .confirmationDialog(
            "Write the selected request to the cable?",
            isPresented: $showWriteConfirmation
        ) {
            Button("Write Line") { viewModel.writePPSLine() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This overwrites the cable's PPS configuration (the recorded PDO list is preserved).")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button("Read Line") { viewModel.readPPSLine() }
                .disabled(!viewModel.deviceConnected || viewModel.busy)
            if let version = viewModel.ppsConfig?.pdVersion {
                Text("Charger: PD\(version)").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func configEditor(_ config: PPSConfig) -> some View {
        Picker("Request", selection: $viewModel.ppsSelection) {
            Text("Lowest").tag(PPSSelection.lowest)
            Text("Highest").tag(PPSSelection.highest)
            Text("Rotate (poll)").tag(PPSSelection.rotate)
            if config.ppsRange != nil {
                Text("PPS arbitrary voltage").tag(PPSSelection.arbitrary)
            }
            // Fixed PDOs are selectable by index; PPS PDOs go through the
            // "arbitrary voltage" option instead.
            ForEach(Array(config.pdos.enumerated()), id: \.offset) { index, pdo in
                if case .fixed = pdo {
                    Text(Self.pdoLabel(index: index, pdo: pdo)).tag(PPSSelection.pdo(index: index))
                }
            }
        }
        .pickerStyle(.menu)
        .fixedSize()

        if viewModel.ppsSelection == .arbitrary, let range = config.ppsRange {
            voltageControl(lowMV: range.minMillivolts, highMV: range.maxMillivolts)
        }

        HStack {
            Button("Write Line") { showWriteConfirmation = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canWritePPSLine)
            Text("Saved: \(Self.volts(config.savedMillivolts))")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func voltageControl(lowMV: Int, highMV: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Target")
                Slider(
                    value: $viewModel.ppsTargetVolts,
                    in: Double(lowMV) / 1000...Double(highMV) / 1000,
                    step: 0.02)
                Text(String(format: "%.2f V", viewModel.ppsTargetVolts))
                    .font(.callout.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
            }
            Text("\(Self.volts(lowMV))–\(Self.volts(highMV)), 20 mV steps")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Formatting

    private static func volts(_ millivolts: Int) -> String {
        String(format: "%.2f V", Double(millivolts) / 1000)
    }

    private static func amps(_ milliamps: Int) -> String {
        String(format: "%.2f A", Double(milliamps) / 1000)
    }

    private static func pdoLabel(index: Int, pdo: PDO) -> String {
        switch pdo {
        case .fixed(let mv, let ma):
            return "PDO \(index + 1) — \(volts(mv)), \(amps(ma)) (fixed)"
        case .pps(let lo, let hi, let ma):
            return "PDO \(index + 1) — \(volts(lo))–\(volts(hi)), \(amps(ma)) (PPS)"
        }
    }
}
