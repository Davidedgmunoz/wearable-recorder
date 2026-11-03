/// Streaming decoder: feed it raw notification bytes in whatever chunks they
/// arrive, get back complete frames.
///
/// Recovery strategy: if a checksum fails, the sync byte we locked onto may be
/// a 0xA5 inside some payload, or the frame may be corrupted. Either way we drop
/// just that one byte and rescan, so a single bad frame never desyncs the stream.
public struct FrameDecoder: Sendable {
  public enum Output: Equatable, Sendable {
    case frame(Frame)
    case corrupted(Corruption)
  }

  public enum Corruption: Equatable, Sendable {
    case badChecksum
    case unknownKind(UInt8)
  }

  private var buffer: [UInt8] = []

  public init() {}

  /// Bytes waiting for the rest of a frame. Useful in logs when a user reports "it stopped".
  public var pendingByteCount: Int { buffer.count }

  public mutating func append(_ chunk: some Sequence<UInt8>) -> [Output] {
    buffer.append(contentsOf: chunk)
    var outputs: [Output] = []

    while let syncIndex = buffer.firstIndex(of: Frame.sync) {
      if syncIndex > 0 { buffer.removeFirst(syncIndex) }
      guard buffer.count >= Frame.headerSize else { break }

      let length = Int(buffer[4])
      let bodyEnd = Frame.headerSize + length
      let frameEnd = bodyEnd + Frame.checksumSize
      guard buffer.count >= frameEnd else { break }

      let expected = CRC16.ccitt(buffer[1..<bodyEnd])
      let received = UInt16(buffer[bodyEnd]) | UInt16(buffer[bodyEnd + 1]) << 8
      guard expected == received else {
        buffer.removeFirst()
        outputs.append(.corrupted(.badChecksum))
        continue
      }

      let kindByte = buffer[1]
      let sequence = UInt16(buffer[2]) | UInt16(buffer[3]) << 8
      let payload = Array(buffer[Frame.headerSize..<bodyEnd])
      buffer.removeFirst(frameEnd)

      if let kind = Frame.Kind(rawValue: kindByte) {
        outputs.append(.frame(Frame(kind: kind, sequence: sequence, payload: payload)))
      } else {
        outputs.append(.corrupted(.unknownKind(kindByte)))
      }
    }

    if buffer.first != Frame.sync { buffer.removeAll() }
    return outputs
  }
}
