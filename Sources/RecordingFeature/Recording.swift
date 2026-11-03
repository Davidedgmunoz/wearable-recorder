import DeviceProtocol
import Foundation

/// An in-progress recording. Summaries only: a real app would stream samples to
/// disk or upload them; the point here is the bookkeeping that keeps data honest.
public struct Recording: Equatable, Codable, Sendable {
  public struct Gap: Equatable, Codable, Sendable {
    public var start: Date
    public var end: Date?
  }

  public var id: UUID
  public var startedAt: Date
  public var framesReceived = 0
  public var sampleCount = 0
  /// Frames the device sent that never arrived, inferred from sequence numbers.
  public var droppedFrames = 0
  public var corruptedFrames = 0
  /// Periods where the link was down.
  public var gaps: [Gap] = []
  /// Most recent value per channel, for the live readout.
  public var latest: [Int16] = []
  var lastSequence: UInt16?

  public init(id: UUID, startedAt: Date) {
    self.id = id
    self.startedAt = startedAt
  }

  public var isLinkDown: Bool { gaps.last.map { $0.end == nil } ?? false }

  mutating func ingest(_ packet: SamplePacket, sequence: UInt16) {
    if let lastSequence {
      // Wrapping arithmetic handles the u16 rollover (65535 → 0) for free.
      let delta = sequence &- (lastSequence &+ 1)
      // A "gap" larger than half the sequence space is really a late or duplicate frame.
      guard delta < 0x8000 else { return }
      droppedFrames += Int(delta)
    }
    lastSequence = sequence
    framesReceived += 1
    sampleCount += packet.steps.count
    latest = packet.steps.last ?? latest
  }

  mutating func linkDropped(at date: Date) {
    guard !isLinkDown else { return }
    gaps.append(Gap(start: date))
    // The device may reboot while away and restart its counter, so don't
    // count frames across the gap; the gap itself records the missing time.
    lastSequence = nil
  }

  mutating func linkRestored(at date: Date) {
    guard isLinkDown else { return }
    gaps[gaps.count - 1].end = date
  }
}

public struct FinishedRecording: Equatable, Identifiable, Sendable {
  public enum Outcome: Equatable, Sendable {
    case completed
    /// Reconnection gave up; everything up to the loss is kept.
    case linkLost
    /// The app was killed mid-recording and found the recording on next launch.
    case recoveredAfterRelaunch
  }

  public var recording: Recording
  public var endedAt: Date
  public var outcome: Outcome

  public var id: UUID { recording.id }
}
