# ContinueTimer

A macOS menu bar app that sends "continue" to a Codex or Claude Code chat once your usage limit has reset, so long-running work picks up again without you being at the keyboard.

> **Agents:** to install this app, follow [installation.md](installation.md) step by step.

## What it does

1. Click the ⏱ icon in the menu bar.
2. Choose **Codex** or **Claude Code** and pick the chat. Recent chats are listed by title, read from `~/.codex/sessions` and `~/.claude/projects`, so chats started in the desktop apps appear too.
3. Enter how long until the limit resets (e.g. 2 h 9 m), and optionally change the message and permissions.
4. Click **Schedule**. The menu bar shows the countdown.

When the timer fires:

| Harness | How the message is delivered |
|---|---|
| Claude Code | Runs `claude --resume <id> --permission-mode <mode> -p "continue"` in the chat's folder. |
| Codex, chat not open in the app | Runs `codex exec resume <id> "continue"` in the chat's folder. |
| Codex, chat open in the ChatGPT/Codex app | The app locks open chats, so the CLI can't write to them. ContinueTimer opens the chat via `codex://threads/<id>`, types the message, presses Return, and confirms delivery by checking that the chat record shows the message within 2 minutes. |

You get a macOS notification when a message is sent and when it succeeds or fails. Each run writes a log to `~/Library/Logs/ContinueTimer/`. Timers survive app restarts. While a timer is pending, the Mac is kept from idle-sleeping, and a timer that came due during sleep fires on wake.

## Limitations

- Typing into the Codex app needs Accessibility permission, an unlocked screen, and brings the app to the front for a few seconds. It replaces any unsent draft in that chat's message box.
- A resumed CLI run happens in the background; an open desktop window shows the new turns only after you reopen the chat.
- If the limit hasn't actually reset yet, the run fails and is not retried.

## Requirements

macOS 14 or later, the Swift toolchain (Xcode or Command Line Tools), and the `codex` and/or `claude` CLI. See [installation.md](installation.md).
