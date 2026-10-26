# MoniVitals — iOS app

A SwiftUI (iOS 16+) + CoreBluetooth companion app for an experimental ECG / BioZ / PPG
wearable. It mirrors the **web app** (`../web`) and shares the algorithm / protocol /
export specifications in [`../docs`](../docs).

> ⚠️ **MoniVitals is a research / science-fair / educational tool, NOT a medical device.**
> It must not be used for diagnosis or any clinical decision. Heart rate, SpO₂, pulse
> arrival time (PAT), and blood-pressure values are uncalibrated *estimates*.

## Generating and building the project

There is no committed `.xcodeproj`; it is generated from
[`project.yml`](project.yml) with [XcodeGen](https://github.com/yonsm/XcodeGen):

```bash
brew install xcodegen
cd ios
xcodegen generate
open MoniVitals.xcodeproj
```

Then select the **MoniVitals** scheme and run on an iOS 16+ simulator or device.

- **CoreBluetooth requires a real device** to talk to hardware. The simulator cannot
  scan/connect, but **Mock mode** makes every screen fully usable without hardware (and
  without a device).
- Bluetooth usage is declared via `NSBluetoothAlwaysUsageDescription` (a research-tool
  rationale) in [`MoniVitals/Resources/Info.plist`](MoniVitals/Resources/Info.plist) /
  `project.yml`.

### Running the tests

The `MoniVitalsTests` target contains XCTest unit tests mirroring the web Vitest suite
(parser round-trips, PAT against the mock ground truth, calibration math, DSP, CSV
export). Run them in Xcode (`⌘U`) or:

```bash
cd ios && xcodegen generate
xcodebuild test -scheme MoniVitals -destination 'platform=iOS Simulator,name=iPhone 15'
```

> The test files require an Xcode test target / Swift toolchain; they cannot run in a
> toolchain-less CI environment (this is why the project is authored, not compiled, here).

## Architecture

The layers match the web app and are kept cleanly separated:

```
MoniVitals/
  App/        MoniVitalsApp (@main), RootView (TabView), OnboardingView (first-run gate)
  BLE/        Protocol (UUIDs / opcodes / rate tables / sentinels), Packets, Parsers,
              Encoders — little-endian, K derived from payload length
  DSP/        DSPConstants (== docs/DSP.md), Filters (Biquad / derivative / moving avg),
              RollingStats, RPeakDetector (Pan–Tompkins + back-search), PpgFootDetector
              (intersecting tangents), PatEstimator, HeartRateEstimator, Spo2Estimator,
              BioZ (ContactMotion + gateEcg), Calibration (OLS / Pearson / fit / predict),
              MetricsEngine
  Source/     MockSignal (deterministic synthetic ECG/PPG/BioZ + exact PAT/HR truth),
              Timebase (uint32 wrap extender + SeqTracker + clock offset),
              DataSource (protocol + Combine event hub + ConnectionState),
              MockSource (timer-driven), BleSource (CBCentralManager wrapper)
  Model/      Models (Codable structs), Store (dependency-free local JSON persistence +
              Recorder pipeline), CSVExport (docs/CSV_FORMAT.md bundle → temp folder)
  Views/      AppModel (ObservableObject store), RingBuffer (WaveBuffer), WaveformStrip
              (Canvas + TimelineView), Connect / Dashboard / Recorder / Calibration /
              Gating / Review / Settings, UIHelpers
  Resources/  Info.plist
MoniVitalsTests/  XCTest unit tests
```

### Data flow

`DataSource` (Mock or BLE) publishes decoded packets on Combine subjects → `AppModel`
pushes high-rate samples into **non-reactive `WaveBuffer` ring buffers** and the
`MetricsEngine`, and (when recording) into the `Recorder`. The `Canvas`-based live strips
read the ring buffers directly on a `TimelineView` tick, so high-rate sample data never
flows through `@Published` state. A 250 ms timer snapshots the engine and publishes
throttled metrics. Swift Charts is used only for **static** plots (Calibration scatter,
Review waveforms), never the 256 Hz live strips.

### Shared spec / parity with the web app

- BLE UUIDs, opcodes, packet layouts, rate tables, and sentinels come from
  [`docs/BLE_PROTOCOL.md`](../docs/BLE_PROTOCOL.md) and match `web/src/ble`.
- DSP constants and algorithms come from [`docs/DSP.md`](../docs/DSP.md); the Swift DSP is
  a line-for-line port of `web/src/dsp` (`Double` arithmetic matches JavaScript IEEE-754,
  so the synthetic signal and detector outputs are comparable).
- The CSV export matches [`docs/CSV_FORMAT.md`](../docs/CSV_FORMAT.md) byte-for-byte
  (fixed column order, RFC-4180 escaping, blank-for-invalid, `z0` forward-fill).

### Deviations from the web app

- **Persistence:** the web uses IndexedDB (Dexie); iOS uses a dependency-free local
  JSON-file store under Application Support (`Store.swift`). Same operations
  (subjects/sessions/chunks/metrics/annotations/calibrations, delete + export), local-first.
- **Export container:** the web emits a `.zip`; iOS writes the bundle as a **folder**
  (one CSV per stream + `session_meta.json`) into a temp directory and shares it via
  `UIActivityViewController`. The file contents are identical.
- **Event delivery:** the web's typed `Emitter` is replaced by Combine `PassthroughSubject`s.
- **Web Bluetooth → CoreBluetooth:** `BleSource` is a `CBCentralManager`/`CBPeripheral`
  wrapper (scan by service UUID, connect, discover, subscribe, parse, timebase-extend,
  seq-track, write opcodes, exponential-backoff reconnect).
