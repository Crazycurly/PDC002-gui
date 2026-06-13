import Foundation

public enum FirmwareGroup: String, CaseIterable, Sendable {
    case fixed = "2.0 Fixed voltage"
    case modes = "2.0 Modes"
    case online = "2.1 Online (PC-configurable)"
    case eprAvs = "2.1 EPR/AVS"
    case mi = "2.1 Xiaomi"
}

public struct FirmwarePreset: Identifiable, Hashable, Sendable {
    /// Bundled resource file name (without the .pd1s extension).
    public let id: String
    public let name: String
    public let group: FirmwareGroup
}

/// The 28 firmware images bundled with the official WITRN tool
/// (PDC002固件_230713), with English labels.
public enum FirmwareCatalog {
    public static let presets: [FirmwarePreset] =
        [5, 7, 9, 10, 12, 15, 20].map {
            FirmwarePreset(id: "2.0-fixed-\($0)v", name: "Fixed \($0) V", group: .fixed)
        } + [
            FirmwarePreset(id: "2.0-highest-blink", name: "Highest (blink)", group: .modes),
            FirmwarePreset(id: "2.0-highest-noblink", name: "Highest (no-blink)", group: .modes),
            FirmwarePreset(id: "2.0-polling-blink", name: "Polling (blink)", group: .modes),
            FirmwarePreset(id: "2.0-polling-noblink", name: "Polling (no-blink)", group: .modes),
            FirmwarePreset(id: "2.1-online-blink", name: "Online (blink)", group: .online),
            FirmwarePreset(id: "2.1-online-noblink", name: "Online (no-blink)", group: .online),
        ] + (15...28).map {
            FirmwarePreset(id: "2.1-epr-avs-\($0)v", name: "EPR/AVS \($0) V", group: .eprAvs)
        } + [
            FirmwarePreset(
                id: "2.1-mi-120w",
                name: "Xiaomi MI 120 W (online, no-blink, save-on-off)",
                group: .mi
            ),
        ]

    public static func preset(id: String) -> FirmwarePreset? {
        presets.first { $0.id == id }
    }

    public static func url(for preset: FirmwarePreset) -> URL? {
        Bundle.module.url(
            forResource: preset.id, withExtension: "pd1s", subdirectory: "firmware")
    }

    public static func load(_ preset: FirmwarePreset) throws -> Firmware {
        guard let url = url(for: preset) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try PD1S.decode(Data(contentsOf: url))
    }

    /// Decoded bodies of all presets, for identifying a read-back image.
    private static let decodedBodies: [(preset: FirmwarePreset, body: Data)] = {
        presets.compactMap { preset in
            (try? load(preset)).map { (preset, $0.body) }
        }
    }()

    /// Match a firmware body read back from the device against the
    /// bundled presets.
    public static func identify(body: Data) -> FirmwarePreset? {
        decodedBodies.first { $0.body == body }?.preset
    }
}
