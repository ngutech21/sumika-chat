/// An alternate workspace execution boundary. SumikaEval supplies Harbor-backed I/O.
package struct WorkspaceExecution: Sendable {
  let fileIO: any WorkspaceFileIO
  let commandRunner: any CommandProcessRunning

  package init(fileIO: any WorkspaceFileIO, commandRunner: any CommandProcessRunning) {
    self.fileIO = fileIO
    self.commandRunner = commandRunner
  }

  var executorRegistry: ToolExecutorRegistry {
    ToolExecutorRegistry([
      AnyToolExecutor(ReadFileToolExecutor()),
      AnyToolExecutor(EditFileToolExecutor()),
      AnyToolExecutor(WriteFileToolExecutor()),
      AnyToolExecutor(
        RunCommandToolExecutor(
          environment: [:], pathPrefixDirectories: [], processRunner: commandRunner)),
      AnyToolExecutor(AskUserToolExecutor()),
      AnyToolExecutor(FinishTaskToolExecutor()),
    ])
  }
}
