<div align="center">

<img src="docs/icon.png" width="128" alt="PDC002 Flasher icon" />

# PDC002 Flasher for macOS

**A native macOS app for flashing firmware onto the WITRN PDC002 USB-C
Power-Delivery trigger cable** — a clean replacement for the Windows-only
`WITRN Upgrade 4.0.exe`.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-555?logo=apple&logoColor=white)](#-build)
[![SwiftUI](https://img.shields.io/badge/SwiftUI-native-FA7343?logo=swift&logoColor=white)](#-how-it-works)
[![Latest release](https://img.shields.io/github/v/release/Crazycurly/PDC002-gui?label=release&color=2ea043)](https://github.com/Crazycurly/PDC002-gui/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Crazycurly/PDC002-gui/total?color=8957e5)](https://github.com/Crazycurly/PDC002-gui/releases)

</div>

---

The PDC002's inline HID programmer (USB VID `0x0716`, PID `0x5036`) accepts
52 KB firmware images that determine which voltage/mode the cable requests
from a PD supply — fixed 5–20 V, highest, polling, EPR/AVS 15–28 V,
Xiaomi MI 120 W, and the PC-configurable **"online"** firmware. This app drives
that programmer natively on macOS: no Windows, no VM, no third-party runtime.

See the [product page](https://www.witrn.com/?p=556) for the cable itself.

<div align="center">

![PDC002 Flasher](docs/screenshot.png)

</div>

## ⚡ Quick start

1. Grab the latest [**`PDC002-vX.Y-macos.zip`**](https://github.com/Crazycurly/PDC002-gui/releases/latest).
2. Unzip and move `PDC002.app` to **Applications**.
3. First launch: **right-click → Open** (the app is ad-hoc signed), or clear
   quarantine with `xattr -dr com.apple.quarantine PDC002.app`.
4. Plug in the PDC002 — the app detects the programmer automatically.

> Requires **macOS 13+** on **Apple Silicon**.

## ✨ Features

- **Live detection** of the PDC002 programmer (connect / disconnect).
- **28 bundled firmware presets** (from the official `PDC002固件_230713` set),
  grouped with English labels — and custom `.pd1s` files can be opened too.
- **Identify** — reads the firmware on the cable and matches it against the
  bundled presets.
- **Safe flashing** with live progress (erase / write / verify) and read-back
  verification *before* the device is reset, so a failed verify never reboots
  the cable into a bad image.
- **PPS arbitrary voltage** (Online / PC-config firmware):
  - **Read Line** (读线) pulls the charger's recorded PDO list and current
    selection from the config block and lays the PDOs out in a table (active
    one highlighted).
  - Pick a request mode — lowest / highest / rotate, or a specific PDO — and,
    for a PPS PDO, a target voltage set with a slider or typed directly
    (clamped to the charger's window and snapped to 20 mV steps).
  - **Write Line** (写线) stores it as a read-modify-write with read-back
    verify; the recorded PDO list is preserved and no reset is issued.
- **Reset** command, plus a bottom status bar showing operation progress and
  the last result.

## 🪟 Layout

A two-column window: firmware selection and flash actions on the left, the
PPS arbitrary-voltage panel (the part used most) given the room on the right,
with a full-width status bar along the bottom.

## 🔨 Build

Requires **macOS 13+** and **Xcode** (for SwiftUI / XCTest). No third-party
dependencies.

```sh
swift test               # hardware-free protocol tests
Scripts/make_app.sh      # release build → ad-hoc signed PDC002.app
open PDC002.app
```

If `xcode-select -p` points at the CommandLineTools, the script selects the
Xcode toolchain via `DEVELOPER_DIR` automatically.

The app icon is rendered from `AppIcon-source.png`: `make_app.sh` runs
`Scripts/make_icon.swift`, which locates the bright subject, crops a centered
square around it, and clips it into the macOS rounded-rect "squircle" with a
drop shadow — re-rendered crisp at every size. It bundles the resulting
`.icns`, regenerating only when the source art or the generator changes.

The app is unsandboxed and ad-hoc signed for local use; vendor-defined HID
devices need no special entitlements or Input Monitoring permission.

## 🔬 How it works

- **HID protocol** (`Sources/PDC002Kit/Protocol/`): 64-byte reports with an
  `FF 55` header, command byte, payload, and two additive checksums.
  Commands: enter prog mode (3), start/end write (5/4), erase pages (8),
  write (9), read info (10), bulk read (11), reset (23). Firmware occupies
  flash addresses `0x2C00–0xFBFF` (52 × 1 KB pages); writes are page-aligned
  chunks of 25×40 + 24 bytes, matching the official tool's traffic.
- **PPS config block** (`PPSConfig.swift`): the Online firmware keeps a
  52-byte block at flash `0xFC00` holding the charger's recorded PDO list
  (4-byte mode words), the selected request mode, the saved target voltage,
  and a trailing additive checksum. It is read with read-info and rewritten
  with a single-page erase + 40-byte / 12-byte write chunks; the PDO decode
  mirrors `pdc-control`'s `readModes`. Re-encoding preserves every unedited
  byte and derives the new checksum as a delta, so an unrecognized field is
  never clobbered.
- **.pd1s container** (`PD1S.swift`, `SBox.swift`): the whole file is passed
  through a fixed 256-byte substitution table. Decoded files start with the
  ASCII magic `gzutapp` and a build date, followed by the raw 53,248-byte
  firmware body. `Scripts/gen_sbox.py` regenerates the table from a known
  raw / encoded pair.
- The protocol layer is pure Swift over a `FrameTransport` abstraction;
  `Tests/PDC002KitTests` exercises it against captured USB traces and a mock
  device, including a full flash + verify cycle.

## 🙏 Credits

The HID protocol was reverse engineered by
[sambenz/PDC002](https://github.com/sambenz/PDC002) (`pdc002.py`, Saleae
traces) — this app mirrors and builds on that work. Firmware images are the
official WITRN releases bundled with their Windows tool. The cable itself is
the [WITRN PDC002](https://www.witrn.com/?p=556).

## ⚠️ Safety

Flashing modifies the cable's firmware. The app verifies by read-back before
resetting — but only ever flash images intended for the PDC002.
