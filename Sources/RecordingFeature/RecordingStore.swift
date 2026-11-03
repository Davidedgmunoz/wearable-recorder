import ComposableArchitecture
import Foundation

/// Checkpoints the in-progress recording so a force-quit or a crash doesn't lose it.
@DependencyClient
public struct RecordingStore: Sendable {
  public var save: @Sendable (_ recording: Recording) async throws -> Void
  public var loadOrphan: @Sendable () async throws -> Recording?
  public var clear: @Sendable () async throws -> Void
}

extension RecordingStore: DependencyKey {
  public static let liveValue: RecordingStore = {
    let url = URL.applicationSupportDirectory.appending(path: "in-progress-recording.json")
    return RecordingStore(
      save: { recording in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recording).write(to: url, options: .atomic)
      },
      loadOrphan: {
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }
        return try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
      },
      clear: {
        guard FileManager.default.fileExists(atPath: url.path()) else { return }
        try FileManager.default.removeItem(at: url)
      }
    )
  }()

  public static let testValue = RecordingStore()

  public static let previewValue = RecordingStore(save: { _ in }, loadOrphan: { nil }, clear: {})
}

extension DependencyValues {
  public var recordingStore: RecordingStore {
    get { self[RecordingStore.self] }
    set { self[RecordingStore.self] = newValue }
  }
}
