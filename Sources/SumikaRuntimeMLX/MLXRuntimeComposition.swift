import SumikaCore

package enum MLXRuntimeComposition {
  package static func makeChatEnvironment(
    overriding runtime: (any ChatModelRuntime)? = nil
  ) -> (runtime: any ChatModelRuntime, turnTracer: any TurnTracing) {
    let debugTraceStore = MLXDebugTraceStore()
    return (
      runtime: runtime ?? MLXChatRuntime(debugTraceStore: debugTraceStore),
      turnTracer: debugTraceStore
    )
  }

  package static func makeModelDownloader() -> any ModelDownloading {
    HuggingFaceModelDownloader()
  }
}
