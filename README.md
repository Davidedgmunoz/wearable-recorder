# Wearable Recorder

A small iOS sample of the part of a wearable app that's hard to get right: talking to a
Bluetooth LE headset that streams sensor data, and never losing a recording when the
link drops, the app is backgrounded or the user force-quits.

Built with Swift 6 (strict concurrency), SwiftUI and The Composable Architecture. It runs
without hardware: a simulated headset streams data in MTU-sized chunks, skips frames now
and then, and drops the link mid-recording so the reconnect path is exercised.

## Modules

```
DeviceProtocol     Pure Swift. Framing, CRC-16, sample payloads, bit-packed config.
      ▲
BLEClient          CoreBluetooth behind an async/AsyncStream dependency + simulated headset.
      ▲
RecordingFeature   TCA reducer + SwiftUI: scan → connect → record → survive link loss.
```

Each is an SPM target, so the protocol code builds and tests with no Apple frameworks,
and the feature never imports CoreBluetooth.

## Things worth looking at

**Wire protocol** (`DeviceProtocol`). Frames are `sync | kind | seq u16 | len | payload | crc16`,
little-endian. `FrameDecoder` is a streaming decoder: BLE notifications split frames at
arbitrary points, and one notification can carry the tail of one frame and the head of the
next. On a bad checksum it drops one byte and rescans, so a `0xA5` inside a payload or a
corrupted frame never desyncs the stream. Recording config is packed into a single byte to
match a firmware bitfield.

**State that can't be wrong** (`RecordingFeature.Phase`). The connection lifecycle is one
enum: `idle`, `connecting`, `connected(Link)`, `reconnecting(Link, attempt:)`, `failed`.
A recording lives inside `Link.session`, so there's no recording without a device, no
scanning while connected, and no pair of booleans that can disagree.

**Link loss mid-recording.** The recording moves into `reconnecting` with it, a gap is
opened, and the app retries with backoff (1 s, 2 s, 4 s). On reconnect the gap is closed
and the device is told to resume. If it gives up, whatever was recorded is kept and marked
as such. Each connection gets a fresh `FrameDecoder`, so a half-received frame from before
the drop is never glued onto bytes from after it.

**Honest data.** Dropped frames are inferred from sequence numbers, with u16 rollover
handled and duplicate or late frames ignored. Counting stops across a link gap, since the
headset may have rebooted and reset its counter. Corrupted frames are counted, not fatal.

**Force-quit.** The in-progress recording is checkpointed to disk when it starts, every
20 frames, and the moment the link drops. On next launch an orphaned checkpoint shows up
in history as "recovered after relaunch".

**Backgrounding.** A recording keeps going in the background (it needs the
`bluetooth-central` background mode in the host app). An idle connection is closed to save
the headset's battery.

**Live CoreBluetooth** (`LiveBLEClient.swift`). Delegate callbacks are bridged to
`async throws` and `AsyncStream`. All mutable state is confined to the same serial queue
CoreBluetooth calls back on, which is why that one class is `@unchecked Sendable`, with
a comment saying why. Connect only returns once services are discovered and notifications
are on.

## Tests

```sh
swift test
```

- Protocol: CRC check value, reassembly at several MTU sizes (parameterized), garbage
  before sync, resync after corruption, sync bytes inside payloads, bit layout.
- Reducer (`TestStore`, `TestClock`): link loss mid-recording → reconnect → resume the same
  recording; giving up after 3 attempts while keeping data; recovery after force-quit;
  backgrounding; corrupted frames.
- Snapshots of the link status card (standby, recording, reconnecting), with baselines
  per platform.

CI runs the same command on GitHub Actions (`.github/workflows/ci.yml`), plus an iOS
Simulator build. Snapshot baselines depend on the OS's font rendering, so they're pinned
to the machine that recorded them and skipped on hosted runners (`CI=true`). A
self-hosted Mac runner with the same image could run them too. Re-record with
`SNAPSHOT_TESTING_RECORD=all swift test`.

## Running it

Open `Package.swift` in Xcode and use the `RecordingView` preview ("Simulated headset").
Tap Scan, pick the headset, start recording, and after about 5 seconds watch it lose the
link and recover. To use it in an app, embed `RecordingView` with
`Store(initialState: .init()) { RecordingFeature() }`. The live dependency talks to real
hardware over a Nordic UART-style service.

## Not included (on purpose)

Sample storage and upload, firmware update (DFU), and multi-device sessions. Each is a
module of its own on top of the same `BLEClient`.
