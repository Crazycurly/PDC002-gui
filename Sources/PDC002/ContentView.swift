import PDC002Kit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var viewModel: FlasherViewModel
    @State private var showFileImporter = false
    @State private var showFlashConfirmation = false
    @State private var showLog = false

    private static let pd1sType = UTType(filenameExtension: "pd1s") ?? .data

    var body: some View {
        VStack(spacing: 12) {
            statusPill
            HStack(alignment: .top, spacing: 12) {
                firmwareList
                detailCard
            }
            PPSPanel(viewModel: viewModel)
            logSection
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

    // MARK: - Firmware list

    private var firmwareList: some View {
        VStack(spacing: 8) {
            List(selection: presetSelection) {
                ForEach(FirmwareGroup.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(FirmwareCatalog.presets.filter { $0.group == group }) { preset in
                            Text(preset.name).tag(preset.id)
                        }
                    }
                }
            }
            .listStyle(.bordered)
            Button("Open .pd1s…") { showFileImporter = true }
                .frame(maxWidth: .infinity)
        }
        .frame(width: 290)
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

    // MARK: - Detail + actions

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let loaded = viewModel.loadedFirmware {
                Text(loaded.name).font(.title3.bold())
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Build date").foregroundStyle(.secondary)
                        Text(loaded.firmware.buildDateString)
                    }
                    GridRow {
                        Text("Size").foregroundStyle(.secondary)
                        Text("\(loaded.firmware.body.count) bytes")
                    }
                    GridRow {
                        Text("Source").foregroundStyle(.secondary)
                        Text(loaded.source).lineLimit(1).truncationMode(.middle)
                    }
                    if loaded.presetID != nil, loaded.source != "Bundled preset" {
                        GridRow {
                            Text("Matches preset").foregroundStyle(.secondary)
                            Text(FirmwareCatalog.preset(id: loaded.presetID!)?.name ?? "")
                        }
                    }
                }
                .font(.callout)
            } else {
                Text("Select a firmware preset or open a .pd1s file.")
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 6) {
                Text("Currently on device:").foregroundStyle(.secondary)
                Text(viewModel.deviceFirmwareName ?? "—")
            }
            .font(.callout)

            Spacer(minLength: 8)

            if viewModel.busy {
                VStack(alignment: .leading, spacing: 4) {
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
            }

            Toggle("Verify after flash", isOn: $viewModel.verifyAfterFlash)
                .toggleStyle(.checkbox)

            HStack {
                Button("Flash") { showFlashConfirmation = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        viewModel.loadedFirmware == nil || !viewModel.deviceConnected
                            || viewModel.busy)
                Button("Identify") { viewModel.identify() }
                    .disabled(!viewModel.deviceConnected || viewModel.busy)
                Button("Reset") { viewModel.resetDevice() }
                    .disabled(!viewModel.deviceConnected || viewModel.busy)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Log

    private var logSection: some View {
        DisclosureGroup("Log", isExpanded: $showLog) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(viewModel.logLines) { line in
                            Text(line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: viewModel.logLines.last?.id) { id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}
