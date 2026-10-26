# ContinueTimer

macOS menu bar app that sends "continue" to a Codex or Claude Code chat once a usage limit has reset.

Pick the harness and chat, enter how long until the limit resets, and schedule. When the timer fires:

- **Claude Code** — runs `claude --resume <id> -p "continue"` in the chat's folder.
- **Codex** — runs `codex exec resume <id> "continue"`. If the chat is open in the Codex desktop app (which locks it), it instead opens the chat via `codex://threads/<id>`, types the message and presses Return, then confirms the chat recorded it.

Logs go to `~/Library/Logs/ContinueTimer/`.

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
./build.sh
open ContinueTimer.app
```

Typing into the Codex app needs Accessibility permission (System Settings → Privacy & Security → Accessibility). The app is ad-hoc signed, so re-grant it after each rebuild.
