import SumikaCore

package enum MLXRuntimeComposition {
  package static func makeChatEnvironment(
    overriding runtime: (any ChatModelRuntime)? = nil,
    applicationStateSnapshotProvider: @escaping RuntimeApplicationStateSnapshotProvider = {
      .unavailable
    }
  ) -> (runtime: any ChatModelRuntime, turnTracer: any TurnTracing) {
    let debugTraceStore = MLXDebugTraceStore()
    return (
      runtime: runtime
        ?? MLXChatRuntime(
          debugTraceStore: debugTraceStore,
          applicationStateSnapshotProvider: applicationStateSnapshotProvider,
          generationActivity: .configured()
        ),
      turnTracer: debugTraceStore
    )
  }

  package static func makeModelDownloader() -> any ModelDownloading {
    HuggingFaceModelDownloader()
  }
}
