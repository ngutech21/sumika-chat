import Foundation

public enum AssistantRenderBlock: Equatable, Identifiable, Sendable {
  case paragraph(Paragraph)
  case codeBlock(CodeBlock)

  public struct BlockID: Hashable, Equatable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
      self.rawValue = rawValue
    }

    public var description: String {
      rawValue
    }
  }

  public struct Paragraph: Equatable, Identifiable, Sendable {
    public let id: BlockID
    public var text: String

    public init(id: BlockID, text: String) {
      self.id = id
      self.text = text
    }
  }

  public struct CodeBlock: Equatable, Identifiable, Sendable {
    public let id: BlockID
    public var language: String?
    public var text: String
    public var isClosed: Bool

    public init(
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

  public var id: BlockID {
    switch self {
    case .paragraph(let paragraph):
      paragraph.id
    case .codeBlock(let codeBlock):
      codeBlock.id
    }
  }
}

public struct AssistantRenderBlockParser: Sendable {
  public init() {}

  public func parse(_ content: String) -> [AssistantRenderBlock] {
    var parser = Parser(content: content)
    return parser.parse()
  }
}

extension AssistantRenderBlockParser {
  private struct Parser {
    let content: String
    var currentIndex: String.Index
    var nextBlockOrdinal = 0
    var blocks: [AssistantRenderBlock] = []

    init(content: String) {
      self.content = content
      self.currentIndex = content.startIndex
    }

    mutating func parse() -> [AssistantRenderBlock] {
      while currentIndex < content.endIndex {
        if let fence = fenceLine(at: currentIndex) {
          appendCodeBlock(openingFence: fence)
        } else {
          appendParagraph()
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
