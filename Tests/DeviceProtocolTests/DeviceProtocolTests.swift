import DeviceProtocol
import Testing

@Suite struct CRC16Tests {
  @Test func matchesStandardCheckValue() {
    // The published check value for CRC-16/CCITT-FALSE.
    #expect(CRC16.ccitt(Array("123456789".utf8)) == 0x29B1)
  }
}

@Suite struct FrameDecoderTests {
  let frame = Frame(kind: .samples, sequence: 0x1234, payload: Array(0..<40))

  @Test func encodesLittleEndianHeader() {
    let bytes = frame.encoded()
    #expect(Array(bytes.prefix(5)) == [0xA5, 0x01, 0x34, 0x12, 40])
    #expect(bytes.count == Frame.headerSize + 40 + Frame.checksumSize)
  }

  @Test(arguments: [1, 3, 20, 47, 1000])
  func reassemblesFramesSplitAcrossNotifications(mtu: Int) {
    var decoder = FrameDecoder()
    let stream = frame.encoded() + Frame(kind: .battery, sequence: 1, payload: [90]).encoded()
    let outputs = stream.chunked(maxLength: mtu).flatMap { decoder.append($0) }
    #expect(outputs == [.frame(frame), .frame(Frame(kind: .battery, sequence: 1, payload: [90]))])
    #expect(decoder.pendingByteCount == 0)
  }

  @Test func skipsLeadingGarbage() {
    var decoder = FrameDecoder()
    #expect(decoder.append([0x00, 0xFF, 0x13] + frame.encoded()) == [.frame(frame)])
  }

  @Test func resyncsAfterCorruptedFrame() {
    var corrupted = frame.encoded()
    corrupted[10] ^= 0xFF
    var decoder = FrameDecoder()
    let outputs = decoder.append(corrupted + frame.encoded())
    #expect(outputs.first == .corrupted(.badChecksum))
    #expect(outputs.last == .frame(frame))
  }

  @Test func syncByteInsidePayloadDoesNotConfuseDecoder() {
    let tricky = Frame(kind: .samples, sequence: 7, payload: [0xA5, 0x01, 0xA5, 0xA5])
    var decoder = FrameDecoder()
    #expect(decoder.append(tricky.encoded()) == [.frame(tricky)])
  }

  @Test func reportsUnknownKind() {
    var bytes: [UInt8] = [0x7F, 0x00, 0x00, 0x00]
    let crc = CRC16.ccitt(bytes)
    bytes = [Frame.sync] + bytes + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8)]
    var decoder = FrameDecoder()
    #expect(decoder.append(bytes) == [.corrupted(.unknownKind(0x7F))])
  }

  @Test func waitsForRestOfFrame() {
    var decoder = FrameDecoder()
    let bytes = frame.encoded()
    #expect(decoder.append(bytes.prefix(10)).isEmpty)
    #expect(decoder.pendingByteCount == 10)
    #expect(decoder.append(bytes.dropFirst(10)) == [.frame(frame)])
  }
}

@Suite struct PayloadTests {
  @Test func samplePacketRoundTripsSignedValues() throws {
    let packet = SamplePacket(steps: [[0, -1, .max, .min], [123, -456, 789, -1011]])
    #expect(SamplePacket(payload: packet.payload) == packet)
  }

  @Test func samplePacketRejectsTruncatedPayload() {
    #expect(SamplePacket(payload: [1, 2, 3]) == nil)
    #expect(SamplePacket(payload: []) == nil)
  }

  @Test(arguments: DeviceConfig.SampleRate.allCases, DeviceConfig.Gain.allCases)
  func configBitPackingRoundTrips(rate: DeviceConfig.SampleRate, gain: DeviceConfig.Gain) {
    let config = DeviceConfig(sampleRate: rate, channelMask: 0b1010, gain: gain)
    #expect(DeviceConfig(packed: config.packed) == config)
  }

  @Test func configMatchesFirmwareBitLayout() {
    // rate=500 Hz (0b10), mask=0b0101, gain=x8 (0b11) → 10 0101 11
    #expect(DeviceConfig(sampleRate: .hz500, channelMask: 0b0101, gain: .x8).packed == 0b1001_0111)
  }

  @Test func channelMaskIgnoresHighBits() {
    #expect(DeviceConfig(channelMask: 0xFF).channelMask == 0x0F)
  }
}
