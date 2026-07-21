# Domain Language

## Conversation lifecycle

- **Selected conversation**: The workspace and session currently shown by the app. Selection is UI navigation and does not start, stop, or switch Core execution.
- **Active conversation**: The validated workspace/session pair currently bound in `SumikaCore`. Conversation intents are available only after activation.
- **Conversation activity**: The active conversation is either idle, working, awaiting tool approval, or awaiting a user answer. A non-idle conversation blocks activation of another session.
- **Final snapshot**: The identified session snapshot published when a conversation is deactivated. The app owns its persistence.

Avoid using **active session** for UI selection; use **selected session** instead.
