import Dispatch
import Foundation

@main
enum SumikaEvalCommand {
  @MainActor
  // Invoked by Swift through @main.
  // swiftlint:disable:next unused_declaration
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
      print(EvaluationOptions.usage)
      return
    }
    do {
      let options = try EvaluationOptions(
        arguments: arguments,
        environment: ProcessInfo.processInfo.environment
      )
      setenv("SUMIKA_DEBUG_TRACE", "1", 1)
      setenv(
        "SUMIKA_DEBUG_TRACE_FILE",
        options.outputDirectory.appending(path: "mlx-trace.jsonl").path(percentEncoded: false),
        1
      )
      let cancellation = EvaluationCancellation()
      let signals = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
          Task { @MainActor in cancellation.requested = true }
        }
        source.resume()
        return source
      }
      let runner = EvaluationRunner(options: options, cancellation: cancellation)
      let exitCode: Int32
      if options.worker {
        setenv("SUMIKA_DEBUG_TRACE", "0", 1)
        let worker = EvaluationWorker(runner: runner)
        exitCode = await worker.run()
      } else {
        exitCode = await runner.run().exitCode
      }
      for source in signals { source.cancel() }
      exit(exitCode)
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}

@MainActor
final class EvaluationCancellation {
  var requested = false {
    didSet { if requested { onRequest?() } }
  }
  var onRequest: (() -> Void)?
}
