# PDC002 Flasher for macOS

A native macOS app for flashing firmware onto the WITRN PDC002 USB-C
Power-Delivery trigger cable — a replacement for the Windows-only
`WITRN Upgrade 4.0.exe`.

The PDC002's inline HID programmer (USB VID `0x0716`, PID `0x5036`) accepts
52 KB firmware images that determine which voltage/mode the cable requests
from a PD supply (fixed 5–20 V, highest, polling, EPR/AVS 15–28 V,
Xiaomi MI 120 W, and PC-configurable "online" firmware).

## Features

- Live detection of the PDC002 programmer (connect/disconnect).
- 28 bundled firmware presets (from the official `PDC002固件_230713` set),
  grouped with English labels; custom `.pd1s` files can be opened too.
- Identify: reads the firmware on the cable and matches it against the
  bundled presets.
- Flash with progress (erase / write / verify) and read-back verification
  before the device is reset, so a failed verify never reboots the cable
  into a bad image.
- PPS arbitrary voltage (Online/PC-config firmware): **Read Line** ("读线")
  reads the charger's recorded PDO list and current selection from the
  config block; pick a request mode (lowest/highest/rotate or a specific
  PDO) and, for a PPS PDO, a target voltage in 20 mV steps, then **Write
  Line** ("写线") stores it (read-modify-write with read-back verify; the
  recorded PDO list is preserved and no reset is issued).
- Reset command and a collapsible raw TX/RX frame log.

## Build

Requires Xcode (for SwiftUI/XCTest). No third-party dependencies.

```sh
swift test               # hardware-free protocol tests
Scripts/make_app.sh      # release build → ad-hoc signed PDC002.app
open PDC002.app
```

If `xcode-select -p` points at the CommandLineTools, the script selects the
Xcode toolchain via `DEVELOPER_DIR` automatically.

The app is unsandboxed and ad-hoc signed for local use; vendor-defined HID
devices need no special entitlements or Input Monitoring permission.

## How it works

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
  with a single-page erase + 40-byte/12-byte write chunks (see
  `reference/PDC002/traces/pps-config.txt`); the PDO decode mirrors
  `pdc-control`'s `readModes`. Re-encoding preserves every unedited byte and
  derives the new checksum as a delta, so an unrecognized field is never
  clobbered.
- **.pd1s container** (`PD1S.swift`, `SBox.swift`): the whole file is passed
  through a fixed 256-byte substitution table. Decoded files start with the
  ASCII magic `gzutapp` and a build date, followed by the raw 53,248-byte
  firmware body. `Scripts/gen_sbox.py` regenerates the table from a known
  raw/encoded pair in `reference/`.
- The protocol layer is pure Swift over a `FrameTransport` abstraction;
  `Tests/PDC002KitTests` exercises it against captured USB traces and a mock
  device, including a full flash + verify cycle.

## Credits

The HID protocol was reverse engineered in `reference/PDC002`
(`pdc002.py`, Saleae traces) — this app mirrors that work. Firmware images
are the official WITRN releases bundled with their Windows tool.

## Safety

Flashing modifies the cable's firmware. The app verifies by read-back
before resetting, but only flash images intended for the PDC002.
