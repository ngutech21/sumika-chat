nonisolated struct MLXCheckpointTokenPrefixAnalysis: Equatable, Sendable {
  let commonPrefixCount: Int
  let firstMismatchIndex: Int?
  let isExactPrefix: Bool
  let isStrictExtension: Bool
  let suffixTokens: [Int]

  init(checkpointTokens: [Int], promptTokens: [Int]) {
    let sharedCount = min(checkpointTokens.count, promptTokens.count)
    var commonPrefixCount = 0
    while commonPrefixCount < sharedCount,
      checkpointTokens[commonPrefixCount] == promptTokens[commonPrefixCount]
    {
      commonPrefixCount += 1
    }

    let isExactPrefix =
      checkpointTokens.count <= promptTokens.count
      && commonPrefixCount == checkpointTokens.count
    self.commonPrefixCount = commonPrefixCount
    firstMismatchIndex = isExactPrefix ? nil : commonPrefixCount
    self.isExactPrefix = isExactPrefix
    isStrictExtension = isExactPrefix && checkpointTokens.count < promptTokens.count
    suffixTokens =
      isExactPrefix ? Array(promptTokens.dropFirst(checkpointTokens.count)) : []
  }
}
