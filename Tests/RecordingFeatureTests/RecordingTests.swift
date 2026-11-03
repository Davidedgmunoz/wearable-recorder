import ComposableArchitecture
import DeviceProtocol
import Foundation
import Testing

@testable import RecordingFeature

@Suite struct RecordingTests {
  let packet = SamplePacket(steps: [[1, 2, 3, 4], [5, 6, 7, 8]])

  @Test func countsDroppedFramesFromSequenceGaps() {
    var recording = Recording(id: UUID(0), startedAt: .distantPast)
    recording.ingest(packet, sequence: 10)
    recording.ingest(packet, sequence: 11)
    recording.ingest(packet, sequence: 15)
    #expect(recording.droppedFrames == 3)
    #expect(recording.framesReceived == 3)
    #expect(recording.sampleCount == 6)
    #expect(recording.latest == [5, 6, 7, 8])
  }

  @Test func handlesSequenceRollover() {
    var recording = Recording(id: UUID(0), startedAt: .distantPast)
    recording.ingest(packet, sequence: .max)
    recording.ingest(packet, sequence: 0)
    #expect(recording.droppedFrames == 0)
  }

  @Test func ignoresDuplicateAndLateFrames() {
    var recording = Recording(id: UUID(0), startedAt: .distantPast)
    recording.ingest(packet, sequence: 100)
    recording.ingest(packet, sequence: 100)
    recording.ingest(packet, sequence: 99)
    #expect(recording.droppedFrames == 0)
    #expect(recording.framesReceived == 1)
  }

  @Test func doesNotCountFramesAcrossALinkGap() {
    // The headset may reboot while disconnected and restart its counter at 0.
    var recording = Recording(id: UUID(0), startedAt: .distantPast)
    recording.ingest(packet, sequence: 500)
    recording.linkDropped(at: Date(timeIntervalSince1970: 1))
    recording.linkRestored(at: Date(timeIntervalSince1970: 3))
    recording.ingest(packet, sequence: 1)
    #expect(recording.droppedFrames == 0)
    #expect(recording.gaps == [.init(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 3))])
  }
}
