import BLEClient
import ComposableArchitecture
import DeviceProtocol
import Foundation

@Reducer
public struct RecordingFeature: Sendable {
  public static let maxReconnectAttempts = 3
  /// Checkpoint the recording to disk every N frames (~2 s at the simulator's rate).
  static let checkpointInterval = 20

  /// The connection lifecycle as one enum, so states that can't happen in the real
  /// world can't be represented either: no recording without a device, no scanning
  /// while connected, no "connected" flag that disagrees with a "reconnecting" flag.
  public enum Phase: Equatable, Sendable {
    case idle(Discovery)
    case connecting(DiscoveredDevice)
    case connected(Link)
    /// Link dropped unexpectedly. `Link` keeps the session, so a recording survives.
    case reconnecting(Link, attempt: Int)
    case failed(DiscoveredDevice, message: String)
  }

  public struct Discovery: Equatable, Sendable {
    public var isScanning = false
    public var devices: IdentifiedArrayOf<DiscoveredDevice> = []

    public init(isScanning: Bool = false, devices: IdentifiedArrayOf<DiscoveredDevice> = []) {
      self.isScanning = isScanning
      self.devices = devices
    }
  }

  public struct Link: Equatable, Sendable {
    public var device: DiscoveredDevice
    public var session: Session = .standby
    public var battery: UInt8?

    public init(device: DiscoveredDevice, session: Session = .standby, battery: UInt8? = nil) {
      self.device = device
      self.session = session
      self.battery = battery
    }
  }

  public enum Session: Equatable, Sendable {
    case standby
    case recording(Recording)
  }

  public enum AppPhase: Equatable, Sendable {
    case active
    case background
  }

  @ObservableState
  public struct State: Equatable {
    public var phase: Phase
    public var config: DeviceConfig
    public var history: [FinishedRecording]
    public var errorMessage: String?

    public init(
      phase: Phase = .idle(Discovery()),
      config: DeviceConfig = DeviceConfig(),
      history: [FinishedRecording] = [],
      errorMessage: String? = nil
    ) {
      self.phase = phase
      self.config = config
      self.history = history
      self.errorMessage = errorMessage
    }
  }

  public enum Action: Sendable {
    case task
    case orphanLoaded(Recording?)
    case scanButtonTapped
    case stopScanButtonTapped
    case deviceDiscovered(DiscoveredDevice)
    case deviceTapped(DiscoveredDevice)
    case connectFinished(Result<Void, BLEError>)
    case decoded(FrameDecoder.Output)
    case linkDropped(DisconnectReason)
    case recordButtonTapped
    case stopButtonTapped
    case disconnectButtonTapped
    case retryButtonTapped
    case backButtonTapped
    case commandFailed(BLEError)
    case appPhaseChanged(AppPhase)
  }

  enum CancelID { case scan, events, reconnect }

  @Dependency(\.bleClient) var ble
  @Dependency(\.recordingStore) var store
  @Dependency(\.continuousClock) var clock
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid

  public init() {}

  public var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .task:
        return .run { [store] send in
          await send(.orphanLoaded(try? await store.loadOrphan()))
        }

      case let .orphanLoaded(orphan):
        guard let orphan else { return .none }
        state.history.insert(FinishedRecording(recording: orphan, endedAt: now, outcome: .recoveredAfterRelaunch), at: 0)
        return .run { [store] _ in try await store.clear() }

      case .scanButtonTapped:
        guard case var .idle(discovery) = state.phase else { return .none }
        discovery.isScanning = true
        state.phase = .idle(discovery)
        return .run { [ble] send in
          for await device in ble.scan() {
            await send(.deviceDiscovered(device))
          }
        }
        .cancellable(id: CancelID.scan, cancelInFlight: true)

      case .stopScanButtonTapped:
        guard case var .idle(discovery) = state.phase else { return .none }
        discovery.isScanning = false
        state.phase = .idle(discovery)
        return .cancel(id: CancelID.scan)

      case let .deviceDiscovered(device):
        guard case var .idle(discovery) = state.phase else { return .none }
        discovery.devices[id: device.id] = device
        state.phase = .idle(discovery)
        return .none

      case let .deviceTapped(device):
        guard case .idle = state.phase else { return .none }
        state.phase = .connecting(device)
        return .merge(.cancel(id: CancelID.scan), connect(device.id))

      case .connectFinished(.success):
        switch state.phase {
        case let .connecting(device):
          state.phase = .connected(Link(device: device))
          return listen(to: device.id)

        case .reconnecting(var link, _):
          var resume = Effect<Action>.none
          if case var .recording(recording) = link.session {
            recording.linkRestored(at: now)
            link.session = .recording(recording)
            resume = sendCommand(.startRecording(state.config), to: link.device.id)
          }
          state.phase = .connected(link)
          return .merge(listen(to: link.device.id), resume)

        default:
          return .none
        }

      case let .connectFinished(.failure(error)):
        switch state.phase {
        case let .connecting(device):
          state.phase = .failed(device, message: error.message)
          return .none
        case let .reconnecting(link, attempt):
          return reconnect(link, attempt: attempt + 1, state: &state)
        default:
          return .none
        }

      case let .decoded(output):
        guard case var .connected(link) = state.phase else { return .none }
        defer { state.phase = .connected(link) }

        guard case let .frame(frame) = output else {
          if case var .recording(recording) = link.session {
            recording.corruptedFrames += 1
            link.session = .recording(recording)
          }
          return .none
        }

        switch frame.kind {
        case .battery:
          link.battery = frame.payload.first
          return .none
        case .samples:
          guard case var .recording(recording) = link.session else { return .none }
          if let packet = SamplePacket(payload: frame.payload) {
            recording.ingest(packet, sequence: frame.sequence)
          } else {
            recording.corruptedFrames += 1
          }
          link.session = .recording(recording)
          return recording.framesReceived.isMultiple(of: Self.checkpointInterval) ? checkpoint(recording) : .none
        case .command:
          return .none
        }

      case let .linkDropped(reason):
        guard case var .connected(link) = state.phase else { return .none }
        if reason == .requested {
          state.phase = .idle(Discovery())
          return .cancel(id: CancelID.events)
        }
        var save = Effect<Action>.none
        if case var .recording(recording) = link.session {
          recording.linkDropped(at: now)
          link.session = .recording(recording)
          save = checkpoint(recording)
        }
        return .merge(.cancel(id: CancelID.events), save, reconnect(link, attempt: 1, state: &state))

      case .recordButtonTapped:
        guard case var .connected(link) = state.phase, link.session == .standby else { return .none }
        let recording = Recording(id: uuid(), startedAt: now)
        link.session = .recording(recording)
        state.phase = .connected(link)
        return .merge(sendCommand(.startRecording(state.config), to: link.device.id), checkpoint(recording))

      case .stopButtonTapped:
        switch state.phase {
        case .connected(var link):
          guard case let .recording(recording) = link.session else { return .none }
          link.session = .standby
          state.phase = .connected(link)
          state.history.insert(FinishedRecording(recording: recording, endedAt: now, outcome: .completed), at: 0)
          return .merge(sendCommand(.stopRecording, to: link.device.id), clearCheckpoint())

        case let .reconnecting(link, _):
          // User gives up waiting: keep what we have, stop trying.
          if case let .recording(recording) = link.session {
            state.history.insert(FinishedRecording(recording: recording, endedAt: now, outcome: .linkLost), at: 0)
          }
          state.phase = .idle(Discovery())
          return .merge(.cancel(id: CancelID.reconnect), clearCheckpoint())

        default:
          return .none
        }

      case .disconnectButtonTapped:
        guard case let .connected(link) = state.phase, link.session == .standby else { return .none }
        return disconnect(link, state: &state)

      case .retryButtonTapped:
        guard case let .failed(device, _) = state.phase else { return .none }
        state.phase = .connecting(device)
        return connect(device.id)

      case .backButtonTapped:
        guard case .failed = state.phase else { return .none }
        state.phase = .idle(Discovery())
        return .none

      case let .commandFailed(error):
        state.errorMessage = error.message
        return .none

      case let .appPhaseChanged(appPhase):
        // Recording keeps running in the background (bluetooth-central background mode).
        // An idle connection doesn't, to save the headset's battery.
        guard appPhase == .background, case let .connected(link) = state.phase, link.session == .standby else {
          return .none
        }
        return disconnect(link, state: &state)
      }
    }
  }

  // MARK: Effects

  private func connect(_ id: DiscoveredDevice.ID) -> Effect<Action> {
    .run { [ble] send in
      do {
        try await ble.connect(id)
        await send(.connectFinished(.success(())))
      } catch {
        await send(.connectFinished(.failure(BLEError(error))))
      }
    }
  }

  /// One decoder per link: a partial frame from before a disconnect must never be
  /// glued onto bytes from after it.
  private func listen(to id: DiscoveredDevice.ID) -> Effect<Action> {
    .run { [ble] send in
      var decoder = FrameDecoder()
      for await event in ble.events(id) {
        switch event {
        case let .received(bytes):
          for output in decoder.append(bytes) {
            await send(.decoded(output))
          }
        case let .disconnected(reason):
          await send(.linkDropped(reason))
          return
        }
      }
    }
    .cancellable(id: CancelID.events, cancelInFlight: true)
  }

  /// Exponential backoff (1 s, 2 s, 4 s). Gives up after `maxReconnectAttempts`,
  /// keeping whatever was recorded.
  private func reconnect(_ link: Link, attempt: Int, state: inout State) -> Effect<Action> {
    guard attempt <= Self.maxReconnectAttempts else {
      if case let .recording(recording) = link.session {
        state.history.insert(FinishedRecording(recording: recording, endedAt: now, outcome: .linkLost), at: 0)
      }
      state.phase = .failed(link.device, message: "Lost connection to \(link.device.name).")
      return clearCheckpoint()
    }
    state.phase = .reconnecting(link, attempt: attempt)
    return .run { [ble, clock] send in
      try await clock.sleep(for: .seconds(1 << (attempt - 1)))
      do {
        try await ble.connect(link.device.id)
        await send(.connectFinished(.success(())))
      } catch is CancellationError {
        return
      } catch {
        await send(.connectFinished(.failure(BLEError(error))))
      }
    }
    .cancellable(id: CancelID.reconnect, cancelInFlight: true)
  }

  private func disconnect(_ link: Link, state: inout State) -> Effect<Action> {
    state.phase = .idle(Discovery())
    return .merge(
      .cancel(id: CancelID.events),
      .run { [ble] _ in await ble.disconnect(link.device.id) }
    )
  }

  private func sendCommand(_ command: DeviceCommand, to id: DiscoveredDevice.ID) -> Effect<Action> {
    .run { [ble] send in
      do {
        try await ble.send(id, command)
      } catch {
        await send(.commandFailed(BLEError(error)))
      }
    }
  }

  private func checkpoint(_ recording: Recording) -> Effect<Action> {
    .run { [store] _ in try await store.save(recording) }
  }

  private func clearCheckpoint() -> Effect<Action> {
    .run { [store] _ in try await store.clear() }
  }
}
