# Agent Loop Target

Sumika's agent loop is a small model/tool state machine. The loop must be
correct when run from the persisted turn history alone; MLX session reuse is a
transparent performance optimization, not part of the control flow.

## Core Loop

```text
while turn is running and iteration budget remains:
  build structured model messages from ChatSession.turns
  call the model with the active tool schema

  if the model returns tool calls:
    append an assistant tool-call boundary
    execute or pause each requested tool according to policy
    append tool observations for completed, denied, failed, or invalid tools
    continue

  if the model returns visible assistant text:
    append the assistant text
    complete the turn
    stop

  if the model returns neither visible text nor tool calls:
    fail the generation with a runtime diagnostic
    stop
```

## Stop Conditions

The loop stops only on one of these conditions:

- visible assistant text with no pending tool call
- an explicit terminal tool, such as `complete` or `ask_user`, if such tools are
  registered for the active agent profile
- a tool approval or user-answer pause
- user cancellation
- iteration budget exhaustion or runtime failure

Duplicate tool calls, cache rebuilds, empty assistant tool-call envelopes, and
reasoning-only output are not successful stop conditions.

## Tool Semantics

- An assistant message with `tool_calls` and empty visible content is a normal
  provider boundary. It must not be displayed or treated as a final empty
  assistant answer.
- Tool observations are appended back to the model as structured `tool`
  messages that match the original call IDs.
- Invalid, unavailable, denied, and failed tools become observations. The model
  gets another iteration while budget remains.
- Duplicate read/list/search calls may be executed again or answered with a
  compact duplicate observation. They must not force finalization.
- Write, edit, command, and other side-effecting tools keep their approval flow.
  Approval pauses the loop; after approval or denial the same loop resumes from
  the updated turn history.

## MLX Session Policy

- The correctness baseline is a fresh `ChatSession(history:)` from the full
  derived model history for each generation.
- Reusing an MLX `ChatSession` is allowed only when the cached prefix exactly
  matches the current model-facing history prefix.
- A reused MLX session receives only the appended message delta and current
  continuation messages.
- A reused MLX session must not resend `ChatSession.instructions` for prompt
  bytes already present in the KV cache.
- Cache identity, cache reuse mode, and prompt rebuild decisions must never
  decide whether an agent turn continues, pauses, completes, or fails.

## UI And Debug Output

- The transcript shows user messages, visible assistant text, and tool records.
  It does not show empty assistant tool-call envelopes as normal assistant
  bubbles.
- Reasoning/thinking output is diagnostic stream state attached to a generation.
  It must not satisfy the requirement for final visible assistant text.
- If the final model event is reasoning-only with no tool call, show a clear
  runtime failure instead of synthesizing a successful assistant answer.
