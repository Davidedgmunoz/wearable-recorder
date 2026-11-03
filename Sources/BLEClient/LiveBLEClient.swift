@preconcurrency import CoreBluetooth
import DeviceProtocol
import Foundation

/// GATT layout of the device (Nordic UART-style service: one write, one notify characteristic).
enum GATT {
  static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
  static let write = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
  static let notify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
}

extension BLEClient {
  public static func live() -> BLEClient {
    let central = LiveCentral()
    return BLEClient(
      scan: { central.scan() },
      connect: { try await central.connect($0) },
      disconnect: { await central.disconnect($0) },
      events: { central.events(for: $0) },
      send: { try await central.write($1.frame.encoded(), to: $0) }
    )
  }
}

/// Bridges CoreBluetooth's delegate callbacks into async/await and AsyncStream.
///
/// `@unchecked Sendable` is deliberate: every stored property is read and written
/// only on `queue`, which is also the queue CoreBluetooth calls the delegate on.
/// That's the isolation guarantee the compiler can't see through CBCentralManager.
final class LiveCentral: NSObject, @unchecked Sendable {
  private let queue = DispatchQueue(label: "wearable.ble.central")
  private var manager: CBCentralManager!

  private var wantsScan = false
  private var scanContinuation: AsyncStream<DiscoveredDevice>.Continuation?
  private var peripherals: [UUID: CBPeripheral] = [:]
  private var writeCharacteristics: [UUID: CBCharacteristic] = [:]
  private var pendingConnects: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private var eventContinuations: [UUID: AsyncStream<DeviceEvent>.Continuation] = [:]

  override init() {
    super.init()
    manager = CBCentralManager(delegate: self, queue: queue)
  }

  func scan() -> AsyncStream<DiscoveredDevice> {
    let (stream, continuation) = AsyncStream<DiscoveredDevice>.makeStream()
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      queue.async {
        self.wantsScan = false
        self.scanContinuation = nil
        self.manager.stopScan()
      }
    }
    queue.async {
      self.scanContinuation?.finish()
      self.scanContinuation = continuation
      self.wantsScan = true
      self.startScanIfReady()
    }
    return stream
  }

  func connect(_ id: UUID) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        guard let peripheral = self.peripherals[id] ?? self.manager.retrievePeripherals(withIdentifiers: [id]).first else {
          continuation.resume(throwing: BLEError(message: "Device is no longer available."))
          return
        }
        self.peripherals[id] = peripheral
        peripheral.delegate = self
        self.pendingConnects.removeValue(forKey: id)?.resume(throwing: CancellationError())
        self.pendingConnects[id] = continuation
        self.manager.connect(peripheral)
      }
    }
  }

  func disconnect(_ id: UUID) async {
    queue.async {
      guard let peripheral = self.peripherals[id] else { return }
      self.manager.cancelPeripheralConnection(peripheral)
    }
  }

  func events(for id: UUID) -> AsyncStream<DeviceEvent> {
    let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
    queue.async {
      self.eventContinuations[id]?.finish()
      self.eventContinuations[id] = continuation
    }
    return stream
  }

  func write(_ bytes: [UInt8], to id: UUID) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      queue.async {
        guard let peripheral = self.peripherals[id], peripheral.state == .connected,
              let characteristic = self.writeCharacteristics[id]
        else {
          continuation.resume(throwing: BLEError(message: "Device is not connected."))
          return
        }
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        for chunk in bytes.chunked(maxLength: mtu) {
          peripheral.writeValue(Data(chunk), for: characteristic, type: .withoutResponse)
        }
        continuation.resume()
      }
    }
  }

  // MARK: Queue-confined helpers

  private func startScanIfReady() {
    guard wantsScan, manager.state == .poweredOn else { return }
    manager.scanForPeripherals(withServices: [GATT.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
  }

  private func failConnect(_ id: UUID, _ message: String) {
    pendingConnects.removeValue(forKey: id)?.resume(throwing: BLEError(message: message))
  }
}

extension LiveCentral: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      startScanIfReady()
    case .poweredOff, .unauthorized, .unsupported:
      for id in pendingConnects.keys { failConnect(id, "Bluetooth is unavailable.") }
      for continuation in eventContinuations.values { continuation.yield(.disconnected(.bluetoothOff)) }
    default:
      break
    }
  }

  func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
    peripherals[peripheral.identifier] = peripheral
    let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Unknown device"
    scanContinuation?.yield(DiscoveredDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue))
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([GATT.service])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
    failConnect(peripheral.identifier, error?.localizedDescription ?? "Could not connect.")
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
    let id = peripheral.identifier
    writeCharacteristics[id] = nil
    if pendingConnects[id] != nil {
      failConnect(id, error?.localizedDescription ?? "Disconnected while connecting.")
      return
    }
    // CoreBluetooth reports a nil error only for cancelPeripheralConnection.
    eventContinuations[id]?.yield(.disconnected(error == nil ? .requested : .linkLost))
  }
}

extension LiveCentral: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
    guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == GATT.service }) else {
      return failConnect(peripheral.identifier, "Device service not found.")
    }
    peripheral.discoverCharacteristics([GATT.write, GATT.notify], for: service)
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
    let characteristics = service.characteristics ?? []
    guard error == nil,
          let write = characteristics.first(where: { $0.uuid == GATT.write }),
          let notify = characteristics.first(where: { $0.uuid == GATT.notify })
    else {
      return failConnect(peripheral.identifier, "Device characteristics not found.")
    }
    writeCharacteristics[peripheral.identifier] = write
    peripheral.setNotifyValue(true, for: notify)
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
    if let error { return failConnect(peripheral.identifier, error.localizedDescription) }
    pendingConnects.removeValue(forKey: peripheral.identifier)?.resume()
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
    guard error == nil, let data = characteristic.value else { return }
    eventContinuations[peripheral.identifier]?.yield(.received([UInt8](data)))
  }
}
