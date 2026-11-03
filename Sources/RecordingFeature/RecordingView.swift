import BLEClient
import ComposableArchitecture
import SwiftUI

public struct RecordingView: View {
  let store: StoreOf<RecordingFeature>
  @Environment(\.scenePhase) private var scenePhase

  public init(store: StoreOf<RecordingFeature>) {
    self.store = store
  }

  public var body: some View {
    NavigationStack {
      content
        .navigationTitle("Recorder")
    }
    .task { await store.send(.task).finish() }
    .onChange(of: scenePhase) { _, newPhase in
      store.send(.appPhaseChanged(newPhase == .background ? .background : .active))
    }
  }

  @ViewBuilder
  private var content: some View {
    switch store.phase {
    case let .idle(discovery):
      List {
        Section {
          if discovery.isScanning {
            Button("Stop scanning") { store.send(.stopScanButtonTapped) }
          } else {
            Button("Scan for headsets") { store.send(.scanButtonTapped) }
          }
        }
        if !discovery.devices.isEmpty {
          Section("Nearby") {
            ForEach(discovery.devices) { device in
              Button { store.send(.deviceTapped(device)) } label: {
                LabeledContent(device.name, value: "\(device.rssi) dBm")
              }
            }
          }
        }
        HistorySection(history: store.history)
      }

    case let .connecting(device):
      ProgressView("Connecting to \(device.name)…")

    case let .connected(link):
      LinkScreen(link: link, reconnectAttempt: nil, store: store)

    case let .reconnecting(link, attempt):
      LinkScreen(link: link, reconnectAttempt: attempt, store: store)

    case let .failed(device, message):
      ContentUnavailableView {
        Label("\(device.name) disconnected", systemImage: "antenna.radiowaves.left.and.right.slash")
      } description: {
        Text(message)
      } actions: {
        Button("Try again") { store.send(.retryButtonTapped) }
        Button("Back to devices") { store.send(.backButtonTapped) }
      }
    }
  }
}

private struct LinkScreen: View {
  let link: RecordingFeature.Link
  let reconnectAttempt: Int?
  let store: StoreOf<RecordingFeature>

  var body: some View {
    VStack(spacing: 24) {
      LinkStatusView(link: link, reconnectAttempt: reconnectAttempt)
      switch link.session {
      case .standby:
        Button("Start recording") { store.send(.recordButtonTapped) }
          .buttonStyle(.borderedProminent)
          .disabled(reconnectAttempt != nil)
        Button("Disconnect", role: .destructive) { store.send(.disconnectButtonTapped) }
          .disabled(reconnectAttempt != nil)
      case .recording:
        Button("Stop recording", role: .destructive) { store.send(.stopButtonTapped) }
          .buttonStyle(.borderedProminent)
      }
      Spacer()
    }
    .padding()
  }
}

/// Pure value-in, view-out: this is what the snapshot tests pin.
public struct LinkStatusView: View {
  let link: RecordingFeature.Link
  let reconnectAttempt: Int?

  public init(link: RecordingFeature.Link, reconnectAttempt: Int?) {
    self.link = link
    self.reconnectAttempt = reconnectAttempt
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(link.device.name).font(.headline)
        Spacer()
        if let battery = link.battery {
          Label("\(battery)%", systemImage: "battery.75percent").labelStyle(.titleAndIcon)
        }
      }

      if let reconnectAttempt {
        Label(
          "Connection lost, reconnecting (\(reconnectAttempt)/\(RecordingFeature.maxReconnectAttempts)). Your recording is safe.",
          systemImage: "arrow.triangle.2.circlepath"
        )
        .foregroundStyle(.orange)
      }

      switch link.session {
      case .standby:
        Text("Ready to record").foregroundStyle(.secondary)
      case let .recording(recording):
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
          GridRow { Text("Samples"); Text("\(recording.sampleCount)").monospacedDigit() }
          GridRow { Text("Dropped frames"); Text("\(recording.droppedFrames)").monospacedDigit() }
          GridRow { Text("Corrupted frames"); Text("\(recording.corruptedFrames)").monospacedDigit() }
          GridRow { Text("Link gaps"); Text("\(recording.gaps.count)").monospacedDigit() }
        }
        if !recording.latest.isEmpty {
          Text(recording.latest.map { String($0) }.joined(separator: "  "))
            .font(.system(.body, design: .monospaced))
        }
      }
    }
    .padding()
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }
}

private struct HistorySection: View {
  let history: [FinishedRecording]

  var body: some View {
    if !history.isEmpty {
      Section("Recordings") {
        ForEach(history) { item in
          VStack(alignment: .leading) {
            Text(item.recording.startedAt, format: .dateTime.hour().minute().second())
            Text("\(item.recording.sampleCount) samples · \(label(for: item.outcome))")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func label(for outcome: FinishedRecording.Outcome) -> String {
    switch outcome {
    case .completed: "Completed"
    case .linkLost: "Saved after connection loss"
    case .recoveredAfterRelaunch: "Recovered after app relaunch"
    }
  }
}

#Preview("Simulated headset") {
  RecordingView(
    store: Store(initialState: RecordingFeature.State()) {
      RecordingFeature()
    } withDependencies: {
      $0.bleClient = .simulated(linkLossAfter: .seconds(5))
    }
  )
}
