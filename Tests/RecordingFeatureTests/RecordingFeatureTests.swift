import BLEClient
import ComposableArchitecture
import DeviceProtocol
import Foundation
import Testing

@testable import RecordingFeature

private let device = DiscoveredDevice(id: UUID(1), name: "Headset", rssi: -50)
private let t0 = Date(timeIntervalSince1970: 1_000)
private let packet = SamplePacket(steps: [[1, 2, 3, 4]])

private func samplesFrame(_ sequence: UInt16) -> [UInt8] {
  Frame(kind: .samples, sequence: sequence, payload: packet.payload).encoded()
}

/// One pre-made event stream per connection, so the test can push bytes into
/// "the second connection" before the reducer has even subscribed to it.
private final class FakeDeviceLink: Sendable {
  private let connections: [(stream: AsyncStream<DeviceEvent>, continuation: AsyncStream<DeviceEvent>.Continuation)]
  private let next = LockIsolated(0)

  init(connections count: Int) {
    connections = (0..<count).map { _ in AsyncStream.makeStream(of: DeviceEvent.self) }
  }

  func events() -> AsyncStream<DeviceEvent> {
    next.withValue { index in
      defer { index += 1 }
      return connections[index].stream
    }
  }

  func connection(_ index: Int) -> AsyncStream<DeviceEvent>.Continuation {
    connections[index].continuation
  }
}

@MainActor
@Suite struct RecordingFeatureTests {
  @Test func linkLossMidRecordingReconnectsAndResumesTheSameRecording() async {
    let clock = TestClock()
    let link = FakeDeviceLink(connections: 2)
    let commands = LockIsolated<[DeviceCommand]>([])
    let checkpoints = LockIsolated<[Recording]>([])

    let store = TestStore(initialState: RecordingFeature.State(phase: .idle(.init(devices: [device])))) {
      RecordingFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = t0
      $0.uuid = .incrementing
      $0.bleClient.connect = { _ in }
      $0.bleClient.disconnect = { _ in }
      $0.bleClient.events = { _ in link.events() }
      $0.bleClient.send = { _, command in commands.withValue { $0.append(command) } }
      $0.recordingStore.save = { recording in checkpoints.withValue { $0.append(recording) } }
      $0.recordingStore.clear = {}
    }

    await store.send(.deviceTapped(device)) {
      $0.phase = .connecting(device)
    }
    await store.receive(\.connectFinished) {
      $0.phase = .connected(.init(device: device))
    }

    var recording = Recording(id: UUID(0), startedAt: t0)
    await store.send(.recordButtonTapped) {
      $0.phase = .connected(.init(device: device, session: .recording(recording)))
    }

    link.connection(0).yield(.received(samplesFrame(1)))
    recording.ingest(packet, sequence: 1)
    await store.receive(\.decoded) {
      $0.phase = .connected(.init(device: device, session: .recording(recording)))
    }

    // The headset drops off mid-recording.
    link.connection(0).yield(.disconnected(.linkLost))
    recording.linkDropped(at: t0)
    await store.receive(\.linkDropped) {
      $0.phase = .reconnecting(.init(device: device, session: .recording(recording)), attempt: 1)
    }

    // First backoff is 1 s, then the link comes back and recording resumes.
    await clock.advance(by: .seconds(1))
    recording.linkRestored(at: t0)
    await store.receive(\.connectFinished) {
      $0.phase = .connected(.init(device: device, session: .recording(recording)))
    }

    link.connection(1).yield(.received(samplesFrame(2)))
    recording.ingest(packet, sequence: 2)
    await store.receive(\.decoded) {
      $0.phase = .connected(.init(device: device, session: .recording(recording)))
    }

    await store.send(.stopButtonTapped) {
      $0.phase = .connected(.init(device: device))
      $0.history = [FinishedRecording(recording: recording, endedAt: t0, outcome: .completed)]
    }
    await store.send(.disconnectButtonTapped) {
      $0.phase = .idle(.init())
    }
    await store.finish()

    #expect(recording.sampleCount == 2)
    #expect(recording.gaps.count == 1)
    #expect(commands.value == [.startRecording(DeviceConfig()), .startRecording(DeviceConfig()), .stopRecording])
    // Checkpointed when recording started and again the moment the link dropped.
    #expect(checkpoints.value.count == 2)
    #expect(checkpoints.value.last?.isLinkDown == true)
  }

  @Test func givesUpAfterMaxAttemptsAndKeepsWhatWasRecorded() async {
    let clock = TestClock()
    let link = FakeDeviceLink(connections: 1)
    let cleared = LockIsolated(false)

    let store = TestStore(initialState: RecordingFeature.State(phase: .connecting(device))) {
      RecordingFeature()
    } withDependencies: {
      $0.continuousClock = clock
      $0.date.now = t0
      $0.uuid = .incrementing
      $0.bleClient.connect = { _ in throw BLEError(message: "Timed out") }
      $0.bleClient.events = { _ in link.events() }
      $0.bleClient.send = { _, _ in }
      $0.recordingStore.save = { _ in }
      $0.recordingStore.clear = { cleared.setValue(true) }
    }

    await store.send(.connectFinished(.success(()))) {
      $0.phase = .connected(.init(device: device))
    }
    var recording = Recording(id: UUID(0), startedAt: t0)
    await store.send(.recordButtonTapped) {
      $0.phase = .connected(.init(device: device, session: .recording(recording)))
    }

    link.connection(0).yield(.disconnected(.linkLost))
    recording.linkDropped(at: t0)
    let lost = RecordingFeature.Link(device: device, session: .recording(recording))
    await store.receive(\.linkDropped) {
      $0.phase = .reconnecting(lost, attempt: 1)
    }

    await clock.advance(by: .seconds(1))
    await store.receive(\.connectFinished) {
      $0.phase = .reconnecting(lost, attempt: 2)
    }
    await clock.advance(by: .seconds(2))
    await store.receive(\.connectFinished) {
      $0.phase = .reconnecting(lost, attempt: 3)
    }
    await clock.advance(by: .seconds(4))
    await store.receive(\.connectFinished) {
      $0.phase = .failed(device, message: "Lost connection to Headset.")
      $0.history = [FinishedRecording(recording: recording, endedAt: t0, outcome: .linkLost)]
    }
    await store.finish()
    #expect(cleared.value)
  }

  @Test func recoversARecordingOrphanedByAForceQuit() async {
    var orphan = Recording(id: UUID(7), startedAt: t0)
    orphan.ingest(packet, sequence: 1)
    let cleared = LockIsolated(false)

    let store = TestStore(initialState: RecordingFeature.State()) {
      RecordingFeature()
    } withDependencies: { [orphan] in
      $0.date.now = t0
      $0.recordingStore.loadOrphan = { orphan }
      $0.recordingStore.clear = { cleared.setValue(true) }
    }

    await store.send(.task)
    await store.receive(\.orphanLoaded) {
      $0.history = [FinishedRecording(recording: orphan, endedAt: t0, outcome: .recoveredAfterRelaunch)]
    }
    await store.finish()
    #expect(cleared.value)
  }

  @Test func backgroundingDisconnectsAnIdleLinkButNotARecording() async {
    let disconnected = LockIsolated(false)
    let store = TestStore(initialState: RecordingFeature.State(phase: .connected(.init(device: device)))) {
      RecordingFeature()
    } withDependencies: {
      $0.bleClient.disconnect = { _ in disconnected.setValue(true) }
    }
    await store.send(.appPhaseChanged(.background)) {
      $0.phase = .idle(.init())
    }
    await store.finish()
    #expect(disconnected.value)

    let recording = Recording(id: UUID(0), startedAt: t0)
    let recordingStore = TestStore(
      initialState: RecordingFeature.State(phase: .connected(.init(device: device, session: .recording(recording))))
    ) {
      RecordingFeature()
    }
    await recordingStore.send(.appPhaseChanged(.background))
  }

  @Test func corruptedFramesAreCountedNotFatal() async {
    let recording = Recording(id: UUID(0), startedAt: t0)
    let store = TestStore(
      initialState: RecordingFeature.State(phase: .connected(.init(device: device, session: .recording(recording))))
    ) {
      RecordingFeature()
    }
    var expected = recording
    expected.corruptedFrames = 1
    await store.send(.decoded(.corrupted(.badChecksum))) {
      $0.phase = .connected(.init(device: device, session: .recording(expected)))
    }
  }
}
