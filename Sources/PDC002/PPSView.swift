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
                        Spacer(minLength: 0)
                    } else {
                        configEditor(config)
                    }
                } else {
                    Text("Read Line to load the cable's recorded PDOs and current selection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

        Divider()

        pdoTable(config)

        HStack {
            Text("Saved: \(Self.volts(config.savedMillivolts))")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Write Line") { showWriteConfirmation = true }
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canWritePPSLine)
        }
    }

    /// The cable's recorded PDO list ("电源能力"), shown so the available
    /// charger capabilities are visible without opening the Request menu.
    private func pdoTable(_ config: PPSConfig) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recorded PDOs (\(config.pdos.count))")
                .font(.callout.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(config.pdos.enumerated()), id: \.offset) { index, pdo in
                        pdoRow(index: index, pdo: pdo, selected: isSelected(index, config))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxHeight: .infinity)
    }

    private func pdoRow(index: Int, pdo: PDO, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .frame(width: 18, alignment: .trailing)
                .foregroundStyle(.secondary)
            switch pdo {
            case .fixed(let mv, let ma):
                Text(Self.volts(mv)).frame(width: 110, alignment: .leading)
                Text(Self.amps(ma)).foregroundStyle(.secondary)
            case .pps(let lo, let hi, let ma):
                Text("\(Self.volts(lo))–\(Self.volts(hi))").frame(width: 110, alignment: .leading)
                Text(Self.amps(ma)).foregroundStyle(.secondary)
                Text("PPS").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.callout.monospacedDigit())
        .fontWeight(selected ? .bold : .regular)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(selected ? Color.accentColor.opacity(0.15) : .clear)
    }

    private func isSelected(_ index: Int, _ config: PPSConfig) -> Bool {
        if case .pdo(let selectedIndex) = config.selection { return selectedIndex == index }
        return false
    }

    private func voltageControl(lowMV: Int, highMV: Int) -> some View {
        let low = Double(lowMV) / 1000
        let high = Double(highMV) / 1000
        // Clamp to the PPS window and snap to a 20 mV step on every edit, so
        // the slider and the typed field stay in agreement and a hand-typed
        // value can't fall outside the charger's range.
        let target = Binding<Double>(
            get: { viewModel.ppsTargetVolts },
            set: { newValue in
                let clamped = min(max(newValue, low), high)
                viewModel.ppsTargetVolts = (clamped / 0.02).rounded() * 0.02
            })
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Target")
                Slider(value: target, in: low...high, step: 0.02)
                TextField("", value: target, format: .number.precision(.fractionLength(2)))
                    .frame(width: 56)
                    .multilineTextAlignment(.trailing)
                    .font(.callout.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                Text("V").foregroundStyle(.secondary)
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
