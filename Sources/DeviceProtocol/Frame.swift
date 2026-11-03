/// One protocol frame, little-endian on the wire:
///
///     ┌──────┬──────┬───────────┬─────┬─────────────┬───────────┐
///     │ 0xA5 │ kind │ seq (u16) │ len │ payload…    │ crc (u16) │
///     └──────┴──────┴───────────┴─────┴─────────────┴───────────┘
///       sync   1B       2B        1B    0…255 B       over kind…payload
///
/// BLE notifications are limited by the negotiated MTU, so a frame can arrive
/// split across several notifications, and one notification can carry the end
/// of one frame and the start of the next. `FrameDecoder` handles both.
public struct Frame: Equatable, Sendable {
  public enum Kind: UInt8, Sendable {
    case samples = 0x01
    case battery = 0x02
    case command = 0x10
  }

  public static let sync: UInt8 = 0xA5
  public static let headerSize = 5
  public static let checksumSize = 2
  public static let maxPayloadSize = Int(UInt8.max)

  public var kind: Kind
  public var sequence: UInt16
  public var payload: [UInt8]

  public init(kind: Kind, sequence: UInt16, payload: [UInt8]) {
    precondition(payload.count <= Self.maxPayloadSize, "Payload exceeds one-byte length field")
    self.kind = kind
    self.sequence = sequence
    self.payload = payload
  }

  public func encoded() -> [UInt8] {
    var body: [UInt8] = [kind.rawValue, UInt8(truncatingIfNeeded: sequence), UInt8(sequence >> 8), UInt8(payload.count)]
    body += payload
    let crc = CRC16.ccitt(body)
    return [Self.sync] + body + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
  }
}

extension Array where Element == UInt8 {
  /// Splits bytes the way a peripheral would push them through notifications of `maxLength`.
  public func chunked(maxLength: Int) -> [[UInt8]] {
    precondition(maxLength > 0)
    return stride(from: 0, to: count, by: maxLength).map { Array(self[$0..<Swift.min($0 + maxLength, count)]) }
  }
}
