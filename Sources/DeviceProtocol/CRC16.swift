/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no final XOR).
///
/// Bit-by-bit on purpose: frames are tiny, and this mirrors the reference
/// implementation a firmware team would hand over in C.
public enum CRC16 {
  public static func ccitt<Bytes: Sequence>(_ bytes: Bytes) -> UInt16 where Bytes.Element == UInt8 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
      crc ^= UInt16(byte) << 8
      for _ in 0..<8 {
        crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
      }
    }
    return crc
  }
}
