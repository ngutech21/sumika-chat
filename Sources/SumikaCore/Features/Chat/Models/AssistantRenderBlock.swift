import Foundation

package enum AssistantRenderBlock: Equatable, Identifiable, Sendable {
  case paragraph(Paragraph)
  case codeBlock(CodeBlock)

  package struct BlockID: Hashable, Equatable, Sendable, CustomStringConvertible {
    package let rawValue: String

    package init(rawValue: String) {
      self.rawValue = rawValue
    }

    package var description: String {
      rawValue
    }
  }

  package struct Paragraph: Equatable, Identifiable, Sendable {
    package let id: BlockID
    package var text: String

    package init(id: BlockID, text: String) {
      self.id = id
      self.text = text
    }
  }

  package struct CodeBlock: Equatable, Identifiable, Sendable {
    package let id: BlockID
    package var language: String?
    package var text: String
    package var isClosed: Bool

    package init(
      id: BlockID,
      language: String?,
      text: String,
      isClosed: Bool
    ) {
      self.id = id
      self.language = language
      self.text = text
      self.isClosed = isClosed
    }
  }

  package var id: BlockID {
    switch self {
    case .paragraph(let paragraph):
      paragraph.id
    case .codeBlock(let codeBlock):
      codeBlock.id
    }
  }
}

package struct AssistantRenderBlockParser: Sendable {
  package init() {}

  package func parse(_ content: String) -> [AssistantRenderBlock] {
    parseTail(of: content, fromUTF16Offset: 0, nextBlockOrdinal: 0).blocks
  }

  // Streaming entry point: blocks are delimited by fence lines, so appending
  // content can only ever change the final block. Callers cache the offset of
  // that block and reparse just the tail instead of the whole message.
  package func parseTail(
    of content: String,
    fromUTF16Offset offset: Int,
    nextBlockOrdinal: Int
  ) -> AssistantRenderBlockTailParse {
    var parser = Parser(
      content: content,
      startIndex: String.Index(utf16Offset: offset, in: content),
      nextBlockOrdinal: nextBlockOrdinal
    )
    let blocks = parser.parse()
    return AssistantRenderBlockTailParse(
      blocks: blocks,
      lastBlockUTF16Offset: parser.lastBlockStartIndex?.utf16Offset(in: content)
    )
  }
}

package struct AssistantRenderBlockTailParse: Sendable, Equatable {
  package let blocks: [AssistantRenderBlock]
  package let lastBlockUTF16Offset: Int?

  package init(blocks: [AssistantRenderBlock], lastBlockUTF16Offset: Int?) {
    self.blocks = blocks
    self.lastBlockUTF16Offset = lastBlockUTF16Offset
  }
}

extension AssistantRenderBlockParser {
  private struct Parser {
    let content: String
    var currentIndex: String.Index
    var nextBlockOrdinal: Int
    var blocks: [AssistantRenderBlock] = []
    var lastBlockStartIndex: String.Index?

    init(content: String, startIndex: String.Index, nextBlockOrdinal: Int) {
      self.content = content
      self.currentIndex = startIndex
      self.nextBlockOrdinal = nextBlockOrdinal
    }

    mutating func parse() -> [AssistantRenderBlock] {
      while currentIndex < content.endIndex {
        let blockStart = currentIndex
        let blockCountBeforeParse = blocks.count
        if let fence = fenceLine(at: currentIndex) {
          appendCodeBlock(openingFence: fence)
        } else {
          appendParagraph()
        }
        if blocks.count > blockCountBeforeParse {
          lastBlockStartIndex = blockStart
        }
      }

      return blocks
    }

    private mutating func appendParagraph() {
      let paragraphStart = currentIndex

      while currentIndex < content.endIndex {
        if fenceLine(at: currentIndex) != nil {
          break
        }
        currentIndex = nextLineStart(after: currentIndex)
      }

      guard paragraphStart < currentIndex else {
        return
      }

      blocks.append(
        .paragraph(
          .init(
            id: nextBlockID(),
            text: String(content[paragraphStart..<currentIndex])
          )
        )
      )
    }

    private mutating func appendCodeBlock(openingFence: FenceLine) {
      let codeStart = openingFence.nextLineStart
      currentIndex = codeStart

      while currentIndex < content.endIndex {
        if let closingFence = fenceLine(at: currentIndex),
          closingFence.markerLength >= openingFence.markerLength,
          closingFence.info == nil
        {
          blocks.append(
            .codeBlock(
              .init(
                id: nextBlockID(),
                language: openingFence.language,
                text: String(content[codeStart..<currentIndex]),
                isClosed: true
              )
            )
          )
          currentIndex = closingFence.nextLineStart
          return
        }

        currentIndex = nextLineStart(after: currentIndex)
      }

      blocks.append(
        .codeBlock(
          .init(
            id: nextBlockID(),
            language: openingFence.language,
            text: String(content[codeStart..<content.endIndex]),
            isClosed: false
          )
        )
      )
    }

    private mutating func nextBlockID() -> AssistantRenderBlock.BlockID {
      defer {
        nextBlockOrdinal += 1
      }
      return AssistantRenderBlock.BlockID(rawValue: "assistant-render-block-\(nextBlockOrdinal)")
    }

    private func fenceLine(at lineStart: String.Index) -> FenceLine? {
      guard
        lineStart == content.startIndex
          || content[content.index(before: lineStart)] == "\n"
      else {
        return nil
      }

      let lineEnd = content[lineStart...].firstIndex(of: "\n") ?? content.endIndex
      let line = content[lineStart..<lineEnd]
      let trimmedLine = line.trimmingPrefix { $0 == " " || $0 == "\t" }
      guard trimmedLine.hasPrefix("```") else {
        return nil
      }

      let markerEnd =
        trimmedLine.firstIndex { $0 != "`" }
        ?? trimmedLine.endIndex
      let markerLength = trimmedLine.distance(from: trimmedLine.startIndex, to: markerEnd)
      guard markerLength >= 3 else {
        return nil
      }

      let info = trimmedLine[markerEnd...].trimmingCharacters(in: .whitespaces)
      return FenceLine(
        markerLength: markerLength,
        info: info.isEmpty ? nil : info,
        nextLineStart: lineEnd < content.endIndex ? content.index(after: lineEnd) : content.endIndex
      )
    }

    private func nextLineStart(after lineStart: String.Index) -> String.Index {
      guard let lineEnd = content[lineStart...].firstIndex(of: "\n") else {
        return content.endIndex
      }
      return content.index(after: lineEnd)
    }
  }

  private struct FenceLine {
    let markerLength: Int
    let info: String?
    let nextLineStart: String.Index

    var language: String? {
      info
    }
  }
}
