# screenbox-mcp

A zero-install MCP server that lets an agent **see and act on a Windows desktop**.

```
client (Claude, pi, Cursor, ...)
   |
   | MCP over stdio (JSON-RPC)
   v
screenbox.ps1 (single file, pure PowerShell)
   |
   | UIAutomationClient + WinForms (already on every Windows)
   v
Windows Desktop (interactive session)
```

## Why this exists

Existing accessibility bridges (including `uia-mcp`) dump the full property bag of every element:

- About **1.2 KB per element**, of which ~150 bytes are what a decision actually needs
- 10 controls take **~12 KB** and force multiple paging round trips
- Actions return `success: true` regardless of whether the world changed

`screenbox` is shaped by two rules:

1. **PROJECTION.** A tool answers with the 8 fields an agent selects on: `ref`, `name`, `cls`, `type`, `aid`, `procId`, `rect`, and `flags`. About **130 bytes per element** — **90% smaller**, a whole window fits in a single turn.
2. **VERIFICATION.** An action answers what can be *proven*, not what was requested: the target state, the target's subtree size, the containing window's subtree size, and the top-level window count, before and after. An action whose effect lands outside the target (a new tab, a spawned dialog) is caught by the window or top-level count (`windowKids=116 -> 121`).

## Tools (5)

| Tool | What it does | Typical size |
|---|---|---|
| `screen_info` | Where this server is: session id, desktop visibility, window count, screen resolution. Run this first: accessibility returns an empty tree from session 0 and does not raise. | ~150 B |
| `screen_windows` | Top-level windows, one compact line each. | ~130 B / window |
| `screen_find` | Search descendants by selector (`cls`, `aid`, `name`, `type`, `procId`, `under`, `top`, `limit`). | ~130 B / item |
| `screen_act` | Perform an action (`invoke`, `default`, `toggle`, `expand`, `collapse`, `select`, `focus`, `setvalue:<text>`, `window:maximize`, `window:minimize`, `window:close`) and verify against the before/after fingerprint. | ~300 B |
| `screen_type` | Type literal text into whatever has keyboard focus via `SendKeys` (reaches menus and custom controls that expose no UIA pattern). | ~250 B |

## Self-describing refs

Refs are not array indices:

- `h262352` — an HWND, resolved via `AutomationElement.FromHandle`
- `r42.983818.4.12` — a UIA runtime id, resolved via `FindFirst`

They survive server restarts, fork-based runners, and quotes pasted across turns.

## Usage

### As an MCP server (stdio)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File screenbox.ps1
```

### Self-test

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File screenbox.ps1 -SelfTest
```

### From command line

```powershell
powershell -NoProfile -File screenbox.ps1 -ListTools
powershell -NoProfile -File screenbox.ps1 -RunTool screen_windows
$env:SCREENBOX_ARGS = '{"aid":"NewTabButton"}'
powershell -NoProfile -File screenbox.ps1 -RunTool screen_find
```

## Prerequisite: interactive session

Accessibility requires an interactive desktop session. Services, SSH sessions, and Scheduled Tasks running as SYSTEM or in session 0 will see an empty tree without errors. Run the server under the logged-in user with `LogonType: Interactive`.

## License

MIT
