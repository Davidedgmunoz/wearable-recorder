import BLEClient
import ComposableArchitecture
import DeviceProtocol
import Foundation
import SnapshotTesting
import SwiftUI
import Testing

@testable import RecordingFeature

/// Baselines are pinned to the machine that recorded them: hosted CI runners render
/// fonts slightly differently, so these only run where the baseline lives (locally,
/// or on a self-hosted runner with the same image).
@MainActor
@Suite(.disabled(if: ProcessInfo.processInfo.environment["CI"] == "true", "Snapshot baselines are pinned to the recording machine"))
struct LinkStatusSnapshotTests {
  let device = DiscoveredDevice(id: UUID(1), name: "Headset", rssi: -50)

  var recording: Recording {
    var recording = Recording(id: UUID(0), startedAt: .distantPast)
    recording.ingest(SamplePacket(steps: [[120, -340, 512, -8]]), sequence: 1)
    recording.ingest(SamplePacket(steps: [[118, -301, 498, -12]]), sequence: 4)
    recording.corruptedFrames = 1
    return recording
  }

  @Test func standby() {
    assertLinkSnapshot(.init(device: device, battery: 82), reconnectAttempt: nil, named: "standby")
  }

  @Test func recordingInProgress() {
    assertLinkSnapshot(.init(device: device, session: .recording(recording), battery: 82), reconnectAttempt: nil, named: "recording")
  }

  @Test func reconnectingKeepsRecordingVisible() {
    var recording = recording
    recording.linkDropped(at: .distantPast)
    assertLinkSnapshot(.init(device: device, session: .recording(recording), battery: 82), reconnectAttempt: 2, named: "reconnecting")
  }

  private func assertLinkSnapshot(
    _ link: RecordingFeature.Link,
    reconnectAttempt: Int?,
    named name: String,
    fileID: StaticString = #fileID,
    filePath: StaticString = #filePath,
    line: UInt = #line,
    column: UInt = #column
  ) {
    let view = LinkStatusView(link: link, reconnectAttempt: reconnectAttempt)
      .padding()
      .frame(width: 390, height: 260, alignment: .top)
      .environment(\.colorScheme, .light)

    #if os(iOS)
      assertSnapshot(
        of: view,
        as: .image(precision: 0.99, perceptualPrecision: 0.98, layout: .fixed(width: 390, height: 260)),
        named: "\(name)-iOS", fileID: fileID, file: filePath, testName: "LinkStatus", line: line, column: column
      )
    #else
      let host = NSHostingView(rootView: view)
      host.appearance = NSAppearance(named: .aqua)
      host.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
      assertSnapshot(
        of: host,
        as: .image(precision: 0.99, perceptualPrecision: 0.98),
        named: "\(name)-macOS", fileID: fileID, file: filePath, testName: "LinkStatus", line: line, column: column
      )
    #endif
  }
}
