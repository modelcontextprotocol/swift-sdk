# FoundationModelsExample

A runnable checklist app showing how **one set of Swift tools** can power both an on-device **Apple Foundation Models** `LanguageModelSession` and an **MCP server** that external coding agents (**OpenCode**, **Claude Code**, or any MCP client) can call.

Both sides read and write the **same JSON file**, so tasks created locally with Apple Intelligence immediately show up in OpenCode or Claude Code — and vice versa — with zero duplicated schemas or glue code.

```text
                       ┌──────────────────────────────────────┐
                       │   Shared FoundationModels.Tool set   │
                       │  add_task · complete_task · list_tasks│
                       │    (@Generable args & structured out) │
                       └───────────┬──────────────┬───────────┘
                                   │              │
          local on-device model    │              │  MCP.Tool(_:) + tool.call(_:)
                                   ▼              ▼
                       ┌───────────────┐      ┌───────────────────────────────┐
                       │ LanguageModel │      │ MCP Server (--mcp over stdio) │
                       │    Session    │      │  OpenCode · Claude Code · CLI │
                       └───────┬───────┘      └───────────────┬───────────────┘
                               └──────────────┬───────────────┘
                                              ▼
                                    /tmp/checklist.json
```

## Requirements

- macOS 26 or later (with Xcode 26+ to build).
- Apple Intelligence enabled in System Settings to run `--prompt` with the on-device `SystemLanguageModel`. (The `--mcp` server mode and the walkthrough fallback work even without on-device model assets.)

---

## 1. Run the 30-second walkthrough

From the repository root:

```bash
swift run FoundationModelsExample
```

This runs all three pieces in one go against a fresh temporary store (it ignores `--store`, so your checklist is never modified):

1. **Local `LanguageModelSession`:** asks the on-device model to add two tasks using `AddTaskTool`.
2. **MCP Server + Client:** exports `[add_task, complete_task, list_tasks]` over an `MCP.Server`, connects an `MCP.Client`, marks a task completed, adds another task, and prints the `structuredContent` JSON.
3. **Client-side bridge (`client.languageModelTools`):** wraps the remote MCP tools back into `[Client.LanguageModelTool]` (conforming to `FoundationModels.Tool`) with a host approval callback and calls `list_tasks`.

---

## 2. Build the binary once (for CLI, OpenCode, and Claude Code)

Build the executable and print its full path:

```bash
swift build --target FoundationModelsExample
echo "$(swift build --show-bin-path)/FoundationModelsExample"
```

Keep that path handy — you will use it below. Let's also pick a shared store path so local runs and MCP clients share the same checklist:

```bash
STORE="/tmp/checklist.json"
BIN="$(swift build --show-bin-path)/FoundationModelsExample"
```

---

## 3. Run actions locally with Foundation Models (`--prompt`)

Pass `--prompt` to run a natural-language instruction on-device with `LanguageModelSession`:

```bash
"$BIN" --store "$STORE" \
  --prompt "Add a high-priority task 'Review Generable MCP bridge' with note 'Check stdio mode', then list open tasks."
```

You will see the exact tool calls the on-device model made and its response:

```text
  [FoundationModels tool call] add_task({"priority": "high", "title": "Review Generable MCP bridge", "notes": "Check stdio mode"})
  [FoundationModels tool call] list_tasks({"includeCompleted": false})
  [FoundationModels response] Added "Review Generable MCP bridge" (high priority). You have 1 open task.
```

---

## 4. Use the same tools in OpenCode

Start the binary with `--mcp` and OpenCode will talk to it over `stdin`/`stdout` using MCP.

1. Add an `opencode.json` file in your project directory (or merge into `~/.config/opencode/opencode.json`), replacing `/ABSOLUTE/PATH/TO/` with the output of `swift build --show-bin-path`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "checklist": {
      "type": "local",
      "command": [
        "/ABSOLUTE/PATH/TO/FoundationModelsExample",
        "--mcp",
        "--store",
        "/tmp/checklist.json"
      ],
      "enabled": true
    }
  }
}
```

2. Launch `opencode` and ask:
   - *"List my open checklist tasks."* (calls `list_tasks` and sees the task you added in Step 3)
   - *"Mark task 1 as completed and add a medium-priority task to write unit tests."* (calls `complete_task` and `add_task`)

---

## 5. Use the same tools in Claude Code

### Option A: One command via the CLI

```bash
claude mcp add checklist -- "$BIN" --mcp --store /tmp/checklist.json
```

### Option B: Project `.mcp.json` file

Create `.mcp.json` in your project root (replacing `/ABSOLUTE/PATH/TO/`):

```json
{
  "mcpServers": {
    "checklist": {
      "command": "/ABSOLUTE/PATH/TO/FoundationModelsExample",
      "args": [
        "--mcp",
        "--store",
        "/tmp/checklist.json"
      ]
    }
  }
}
```

Start `claude`, run `/mcp` to confirm `checklist` is connected, and ask Claude to list, add, or complete tasks. Afterward, you can run `--prompt` locally again (Step 3) and the on-device Apple model will see every change Claude Code made.

---

## 6. Inspect the server from the terminal (optional)

You can inspect the generated JSON Schemas (`inputSchema` and `outputSchema`) interactively with the official MCP Inspector:

```bash
npx @modelcontextprotocol/inspector "$BIN" --mcp --store /tmp/checklist.json
```

---

## How it works (`main.swift`)

| Section in `main.swift` | What it demonstrates |
| --- | --- |
| `TaskPriority`, `ChecklistTask`, `ChecklistReport` | `@Generable` models used as both Foundation Models structured outputs and MCP `outputSchema` / `structuredContent`. |
| `AddTaskTool`, `CompleteTaskTool`, `ListTasksTool` | Standard `FoundationModels.Tool` types with `@Generable` `Arguments` and `@Guide` descriptions/constraints. |
| `ChecklistToolset.localTools` | Passes `[addTask, completeTask, listTasks]` directly to `LanguageModelSession(tools:instructions:)`. |
| `ChecklistToolset.makeMCPServer()` | Publishes each tool with `try MCP.Tool(tool, annotations: ...)` and dispatches `CallTool` with `try await tool.call(params)` — turning `LocalizedError` failures into `isError: true` tool results automatically. |
| `runWalkthrough` Step 3 | Uses `try await client.languageModelTools { tool, args in ... }` to wrap remote MCP tools back into `[Client.LanguageModelTool]` for a client-side `LanguageModelSession`. |
