import Dependencies
import DependenciesMacros
import DeviceProtocol
import Foundation

public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var rssi: Int

  public init(id: UUID, name: String, rssi: Int) {
    self.id = id
    self.name = name
    self.rssi = rssi
  }
}

public enum DeviceEvent: Equatable, Sendable {
  /// Raw bytes from one notification. May hold part of a frame, or several.
  case received([UInt8])
  case disconnected(DisconnectReason)
}

public enum DisconnectReason: Equatable, Sendable {
  case requested
  case linkLost
  case bluetoothOff
}

public struct BLEError: Error, Equatable, Sendable {
  public var message: String

  public init(message: String) { self.message = message }

  public init(_ error: any Error) {
    message = (error as? BLEError)?.message ?? error.localizedDescription
  }
}

/// The app's whole view of Bluetooth. Features depend on this, never on CoreBluetooth,
/// so reducers are testable with a scripted device and previews run on a simulated one.
@DependencyClient
public struct BLEClient: Sendable {
  /// Discovered peripherals advertising the device service. Ends when the consumer cancels.
  public var scan: @Sendable () -> AsyncStream<DiscoveredDevice> = { .finished }
  /// Returns once the link is ready: services discovered and notifications enabled.
  public var connect: @Sendable (_ id: DiscoveredDevice.ID) async throws -> Void
  public var disconnect: @Sendable (_ id: DiscoveredDevice.ID) async -> Void
  /// A fresh stream per call. Cancelling the consuming task releases it.
  public var events: @Sendable (_ id: DiscoveredDevice.ID) -> AsyncStream<DeviceEvent> = { _ in .finished }
  public var send: @Sendable (_ id: DiscoveredDevice.ID, _ command: DeviceCommand) async throws -> Void
}

extension BLEClient: TestDependencyKey {
  public static let testValue = BLEClient()
  public static let previewValue = BLEClient.simulated()
}

extension BLEClient: DependencyKey {
  public static var liveValue: BLEClient { .live() }
}

extension DependencyValues {
  public var bleClient: BLEClient {
    get { self[BLEClient.self] }
    set { self[BLEClient.self] = newValue }
  }
}

extension AsyncStream {
  static var finished: Self { AsyncStream { $0.finish() } }
}
