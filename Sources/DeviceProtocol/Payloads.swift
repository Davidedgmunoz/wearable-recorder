/// A block of samples: N time steps × 4 channels of signed 16-bit values, little-endian,
/// interleaved by time step (t0c0 t0c1 t0c2 t0c3 t1c0 …).
public struct SamplePacket: Equatable, Sendable {
  public static let channelCount = 4
  static let bytesPerStep = channelCount * MemoryLayout<Int16>.size

  public var steps: [[Int16]]

  public init(steps: [[Int16]]) {
    precondition(steps.allSatisfy { $0.count == Self.channelCount })
    self.steps = steps
  }

  public init?(payload: [UInt8]) {
    guard !payload.isEmpty, payload.count.isMultiple(of: Self.bytesPerStep) else { return nil }
    steps = stride(from: 0, to: payload.count, by: Self.bytesPerStep).map { start in
      (0..<Self.channelCount).map { channel in
        let offset = start + channel * 2
        return Int16(bitPattern: UInt16(payload[offset]) | UInt16(payload[offset + 1]) << 8)
      }
    }
  }

  public var payload: [UInt8] {
    steps.flatMap { step in
      step.flatMap { value -> [UInt8] in
        let raw = UInt16(bitPattern: value)
        return [UInt8(truncatingIfNeeded: raw), UInt8(raw >> 8)]
      }
    }
  }
}

/// Recording configuration packed into one byte, matching the firmware's bitfield:
///
///     bit  7 6 │ 5 4 3 2      │ 1 0
///          rate│ channel mask │ gain
public struct DeviceConfig: Equatable, Sendable {
  public enum SampleRate: UInt8, CaseIterable, Sendable { case hz125, hz250, hz500, hz1000 }
  public enum Gain: UInt8, CaseIterable, Sendable { case x1, x2, x4, x8 }

  public var sampleRate: SampleRate
  /// Low 4 bits, one per channel.
  public var channelMask: UInt8
  public var gain: Gain

  public init(sampleRate: SampleRate = .hz250, channelMask: UInt8 = 0b1111, gain: Gain = .x4) {
    self.sampleRate = sampleRate
    self.channelMask = channelMask & 0x0F
    self.gain = gain
  }

  public init(packed: UInt8) {
    // Every 2-bit value maps to a case, so these lookups can't fail.
    sampleRate = SampleRate(rawValue: packed >> 6) ?? .hz250
    channelMask = (packed >> 2) & 0x0F
    gain = Gain(rawValue: packed & 0x03) ?? .x1
  }

  public var packed: UInt8 {
    sampleRate.rawValue << 6 | (channelMask & 0x0F) << 2 | gain.rawValue
  }
}

public enum DeviceCommand: Equatable, Sendable {
  case startRecording(DeviceConfig)
  case stopRecording

  public var frame: Frame {
    switch self {
    case let .startRecording(config): Frame(kind: .command, sequence: 0, payload: [0x01, config.packed])
    case .stopRecording: Frame(kind: .command, sequence: 0, payload: [0x02])
    }
  }
}
