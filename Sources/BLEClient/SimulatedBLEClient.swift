import DeviceProtocol
import Foundation

extension BLEClient {
  /// A fake headset for previews and the simulator: streams sine-wave samples split
  /// into 20-byte notifications, skips a frame now and then, and drops the link once
  /// after `linkLossAfter` so the reconnect path can be exercised without hardware.
  public static func simulated(linkLossAfter: Duration? = .seconds(6)) -> BLEClient {
    let device = DiscoveredDevice(
      id: UUID(uuidString: "05EAD5E7-0000-4000-8000-000000000001")!,
      name: "Headset (simulated)",
      rssi: -54
    )
    let peripheral = SimulatedPeripheral(linkLossAfter: linkLossAfter)
    return BLEClient(
      scan: {
        AsyncStream { continuation in
          let task = Task {
            try? await Task.sleep(for: .milliseconds(500))
            continuation.yield(device)
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      },
      connect: { _ in
        try await Task.sleep(for: .milliseconds(600))
        await peripheral.connect()
      },
      disconnect: { _ in await peripheral.disconnect(reason: .requested) },
      events: { _ in peripheral.events() },
      send: { _, command in await peripheral.handle(command) }
    )
  }
}

actor SimulatedPeripheral {
  private let linkLossAfter: Duration?
  private var continuation: AsyncStream<DeviceEvent>.Continuation?
  private var streaming: Task<Void, Never>?
  private var sequence: UInt16 = 0
  private var hasDroppedLink = false

  init(linkLossAfter: Duration?) {
    self.linkLossAfter = linkLossAfter
  }

  nonisolated func events() -> AsyncStream<DeviceEvent> {
    let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream()
    Task { await attach(continuation) }
    return stream
  }

  func connect() {
    emit(Frame(kind: .battery, sequence: 0, payload: [87]))
  }

  func disconnect(reason: DisconnectReason) {
    streaming?.cancel()
    streaming = nil
    continuation?.yield(.disconnected(reason))
  }

  func handle(_ command: DeviceCommand) {
    switch command {
    case .startRecording:
      startStreaming()
    case .stopRecording:
      streaming?.cancel()
      streaming = nil
    }
  }

  private func attach(_ newContinuation: AsyncStream<DeviceEvent>.Continuation) {
    continuation?.finish()
    continuation = newContinuation
  }

  private func startStreaming() {
    streaming?.cancel()
    let start = ContinuousClock.now
    streaming = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled else { return }
        if shouldDropLink(since: start) {
          return disconnect(reason: .linkLost)
        }
        emitSamples()
      }
    }
  }

  private func shouldDropLink(since start: ContinuousClock.Instant) -> Bool {
    guard let linkLossAfter, !hasDroppedLink, ContinuousClock.now - start > linkLossAfter else { return false }
    hasDroppedLink = true
    return true
  }

  private func emitSamples() {
    sequence &+= 1
    // Every 37th frame never makes it over the air, like a missed notification.
    if sequence.isMultiple(of: 37) { return }
    let base = Double(sequence) * 10
    let steps = (0..<10).map { step in
      (0..<SamplePacket.channelCount).map { channel in
        Int16(sin((base + Double(step)) / 12 + Double(channel)) * 800)
      }
    }
    emit(Frame(kind: .samples, sequence: sequence, payload: SamplePacket(steps: steps).payload))
  }

  private func emit(_ frame: Frame) {
    for chunk in frame.encoded().chunked(maxLength: 20) {
      continuation?.yield(.received(chunk))
    }
  }
}
