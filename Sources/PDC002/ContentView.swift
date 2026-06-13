import PDC002Kit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: FlasherViewModel
    @State private var showFileImporter = false
    @State private var showFlashConfirmation = false

    private static let pd1sType = UTType(filenameExtension: "pd1s") ?? .data

    var body: some View {
        VStack(spacing: 12) {
            statusPill
            HStack(alignment: .top, spacing: 12) {
                firmwareCard
                    .frame(width: 260)
                PPSPanel(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            statusBar
        }
        .padding(12)
        .alert(
            "Error", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [Self.pd1sType, .data]
        ) { result in
            if case .success(let url) = result {
                viewModel.openCustomFile(url)
            }
        }
        .confirmationDialog(
            "Flash \"\(viewModel.loadedFirmware?.name ?? "")\" to the cable?",
            isPresented: $showFlashConfirmation
        ) {
            Button("Flash", role: .destructive) { viewModel.flash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This overwrites the firmware on the connected PDC002 cable. Do not unplug while flashing.")
        }
    }

    // MARK: - Status

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.deviceConnected ? Color.green : Color.gray)
                .frame(width: 10, height: 10)
            Text(
                viewModel.deviceManager.deviceName.map { "PDC002 connected — \($0)" }
                    ?? "No device — plug in the PDC002 programmer")
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
    }

    /// Operation output (progress while busy, last result otherwise), shown
    /// full-width along the bottom where the log panel used to be.
    @ViewBuilder
    private var statusBar: some View {
        Group {
            if viewModel.busy {
                HStack(spacing: 10) {
                    Text(viewModel.phaseDescription + "…").font(.callout)
                    if let progress = viewModel.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
            } else if let status = viewModel.statusMessage {
                Label(status, systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Text("Ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Firmware (compact)

    private var firmwareCard: some View {
        GroupBox("Firmware") {
            VStack(alignment: .leading, spacing: 8) {
                List(selection: presetSelection) {
                    ForEach(FirmwareGroup.allCases, id: \.self) { group in
                        Section(group.rawValue) {
                            ForEach(FirmwareCatalog.presets.filter { $0.group == group }) { preset in
                                Text(preset.name).tag(String?.some(preset.id))
                            }
                        }
                    }
                }
                .listStyle(.bordered)
                .frame(height: 132)

                Button("Open .pd1s…") { showFileImporter = true }
                    .frame(maxWidth: .infinity)

                firmwareDetailLine

                HStack(spacing: 6) {
                    Text("On device:").foregroundStyle(.secondary)
                    Text(viewModel.deviceFirmwareName ?? "—").lineLimit(1)
                }
                .font(.callout)

                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    @ViewBuilder
    private var firmwareDetailLine: some View {
        if let loaded = viewModel.loadedFirmware {
            let isFile = loaded.source != "Bundled preset"
            VStack(alignment: .leading, spacing: 2) {
                if isFile {
                    Text(loaded.name).lineLimit(1).truncationMode(.middle)
                }
                Text("Build \(loaded.firmware.buildDateString) · \(loaded.firmware.body.count) bytes")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        } else {
            Text("Select a firmware preset or open a .pd1s file.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 8) {
            HStack {
                Toggle("Verify", isOn: $viewModel.verifyAfterFlash)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Flash") { showFlashConfirmation = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        viewModel.loadedFirmware == nil || !viewModel.deviceConnected
                            || viewModel.busy)
            }
            HStack {
                Button("Identify") { viewModel.identify() }
                    .frame(maxWidth: .infinity)
                    .disabled(!viewModel.deviceConnected || viewModel.busy)
                Button("Reset") { viewModel.resetDevice() }
                    .frame(maxWidth: .infinity)
                    .disabled(!viewModel.deviceConnected || viewModel.busy)
            }
        }
    }

    private var presetSelection: Binding<String?> {
        .init(
            get: { viewModel.selectedPresetID },
            set: { id in
                if let id, let preset = FirmwareCatalog.preset(id: id) {
                    viewModel.selectPreset(preset)
                }
            })
    }
}
