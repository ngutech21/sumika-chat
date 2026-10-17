import Dispatch
import Foundation

struct EvaluationWorkerRequest: Decodable {
  let checkpointID: String
  let networkPolicy: EvaluationNetworkPolicy
}

struct EvaluationWorkerResponse: Codable {
  static let prefix = "SUMIKA_EVAL_WORKER "
  let checkpointID: String
  let result: EvaluationResult

  func line() throws -> Data {
    var data = Data(Self.prefix.utf8)
    data.append(try JSONEncoder().encode(self))
    data.append(0x0A)
    return data
  }
}

@MainActor
final class EvaluationWorker {
  private let runner: EvaluationRunner
  private var checkpointActive = false

  init(runner: EvaluationRunner) {
    self.runner = runner
  }

  func run(
    input: FileHandle = .standardInput,
    emit: (EvaluationWorkerResponse) throws -> Void = {
      try FileHandle.standardOutput.write(contentsOf: $0.line())
    }
  ) async -> Int32 {
    let (chunks, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
    let source = DispatchSource.makeReadSource(
      fileDescriptor: input.fileDescriptor, queue: .global(qos: .utility))
    source.setEventHandler { @Sendable [weak self] in
      do {
        // Foundation pipe reads can wait for the requested count; consume only ready bytes.
        let count = max(1, Int(min(source.data, 65_536)))
        let data = try input.read(upToCount: count) ?? Data()
        if data.isEmpty {
          continuation.finish()
          Task { @MainActor in
            if self?.checkpointActive == true { self?.runner.cancellation.requested = true }
          }
        } else {
          continuation.yield(data)
        }
      } catch {
        continuation.finish(throwing: error)
        Task { @MainActor in
          if self?.checkpointActive == true { self?.runner.cancellation.requested = true }
        }
      }
    }
    continuation.onTermination = { _ in source.cancel() }
    runner.cancellation.onRequest = { continuation.finish() }
    source.resume()
    if runner.cancellation.requested || Task.isCancelled { continuation.finish() }
    var exitCode: Int32 = 0
    do {
      var pending = Data()
      var checkpointIDs: Set<String> = []
      requestLoop: for try await chunk in chunks {
        pending.append(chunk)
        guard pending.count <= 1_048_576 else {
          throw EvaluationError("Worker request is too large")
        }
        while let newline = pending.firstIndex(of: 0x0A) {
          let line = pending.prefix(upTo: newline)
          pending.removeSubrange(...newline)
          guard !runner.cancellation.requested, !Task.isCancelled else { break requestLoop }
          let request = try JSONDecoder().decode(EvaluationWorkerRequest.self, from: line)
          guard !request.checkpointID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            checkpointIDs.insert(request.checkpointID).inserted
          else { throw EvaluationError("Worker checkpoint IDs must be nonempty and unique") }
          setenv("SUMIKA_DEBUG_TRACE", "1", 1)
          checkpointActive = true
          let result = await runner.runCheckpoint(networkPolicy: request.networkPolicy)
          checkpointActive = false
          // Cancellation can finish the consumer before the producer's terminal trace.
          if !result.canResumeWorker { await runner.shutdown() }
          setenv("SUMIKA_DEBUG_TRACE", "0", 1)
          try emit(EvaluationWorkerResponse(checkpointID: request.checkpointID, result: result))
          exitCode = result.exitCode
          guard result.canResumeWorker else {
            break requestLoop
          }
        }
      }
      if !pending.isEmpty, !runner.cancellation.requested {
        throw EvaluationError("Worker requests must end with a newline")
      }
      if runner.cancellation.requested || Task.isCancelled {
        exitCode = EvaluationOutcome.cancelled.exitCode
      }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exitCode = 1
    }
    setenv("SUMIKA_DEBUG_TRACE", "0", 1)
    runner.cancellation.onRequest = nil
    continuation.finish()
    source.cancel()
    await runner.shutdown()
    return exitCode
  }
}
