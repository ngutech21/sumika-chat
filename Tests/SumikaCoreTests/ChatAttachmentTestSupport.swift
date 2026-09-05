import Foundation

@testable import SumikaCore

func makeTextChatAttachment(
  id: AttachmentID = AttachmentID(),
  displayName: String,
  content: String,
  byteSize: Int? = nil,
  contentSHA256: String = ""
) -> ChatAttachment {
  ChatAttachment(
    id: id,
    displayName: displayName,
    payload: .text(
      TextAttachmentPayload(
        content: content,
        byteSize: byteSize ?? content.utf8.count,
        contentSHA256: contentSHA256
      )
    )
  )
}

func makeImageChatAttachment(
  id: AttachmentID = AttachmentID(),
  displayName: String,
  mimeType: String = "image",
  byteSize: Int,
  contentSHA256: String = ""
) -> ChatAttachment {
  ChatAttachment(
    id: id,
    displayName: displayName,
    payload: .image(
      ImageAttachmentPayload(
        mimeType: mimeType,
        byteSize: byteSize,
        contentSHA256: contentSHA256
      )
    )
  )
}

func isolatedAttachmentLifecycle() -> ChatAttachmentLifecycle {
  ChatAttachmentLifecycle(
    store: ChatAttachmentStore(
      baseURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
  )
}

func fixtureAttachmentImport(_ attachments: [ChatAttachment], lifecycle: ChatAttachmentLifecycle)
  -> ChatAttachmentImport
{
  ChatAttachmentImport(
    attachments: attachments, lease: lifecycle.protect(Set(attachments.map(\.id))))
}
