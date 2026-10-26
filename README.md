# ContinueTimer

A macOS menu bar app that sends "continue" (or any message) to a Codex or Claude Code chat once your usage limit has reset, so long-running work picks up again without you being at the keyboard. It can also start a new task at a set time.

> **Agents:** to install this app, follow [installation.md](installation.md) step by step.

## What it does

1. Click the ⏱ icon in the menu bar.
2. Choose **Codex** or **Claude Code**, then **Continue a chat** and pick the chat. Recent chats are listed by title with their current context size (e.g. `· 341k`), read from `~/.codex/sessions` and `~/.claude/projects`, so chats started in the desktop apps appear too.
3. Choose **Resume** or **Fresh + handoff** (see below).
4. Enter how long until the limit resets (e.g. 2 h 9 m), and optionally change the message (any text, default "continue") and permissions.
5. Click **Schedule**. The menu bar shows the countdown.

To start something new instead, choose **New task**, pick a folder (from your recent chats' folders, or any folder via the folder button) and write the prompt. At the set time it runs `claude -p "<prompt>"` or `codex exec "<prompt>"` there.

### Resume vs. fresh session

After a multi-hour limit wait the prompt cache has expired, so resuming re-reads the whole conversation uncached and uses up a large share of the fresh limit. For chats above 100k tokens the app warns about this and defaults to **Fresh + handoff**: it starts a new session in the same folder with a short summary built from the old transcript (original request, latest user messages, last plan, last assistant message, each subagent's status and final report, pointers to the transcripts). Building it needs no model call; it is typically 1–5k tokens instead of several hundred thousand.

The subagents section matters for orchestrator chats: a new session can't list or message the old session's subagents, so the handoff tells it which ones ran, whether they finished, and what they reported, to avoid redoing their work. (Codex encrypts the task it sends a subagent, so for Codex only the subagent's name and result are shown.) **Preview** shows the exact handoff. Switch to **Resume** when the full context matters.

When the timer fires:

| Harness | How the message is delivered |
|---|---|
| Claude Code, resume | Runs `claude --resume <id> --permission-mode <mode> -p "<message>"` in the chat's folder. |
| Codex, resume, chat not open in the app | Runs `codex exec resume <id> "<message>"` in the chat's folder. |
| Codex, resume, chat open in the ChatGPT/Codex app | The app locks open chats, so the CLI can't write to them. ContinueTimer opens the chat via `codex://threads/<id>`, types the message, presses Return, and confirms delivery by checking that the chat record shows the message within 2 minutes. |
| New task | Runs `claude -p "<prompt>"` or `codex exec "<prompt>"` in the chosen folder. |
| Fresh + handoff | Runs `claude -p "<handoff>"` or `codex exec "<handoff>"` in the chat's folder, starting a new session. The handoff ends with your message. |

You get a macOS notification when a message is sent and when it succeeds or fails. Each run writes a log to `~/Library/Logs/ContinueTimer/`. Timers survive app restarts. While a timer is pending, the Mac is kept from idle-sleeping, and a timer that came due during sleep fires on wake.

## Limitations

- Typing into the Codex app needs Accessibility permission, an unlocked screen, and brings the app to the front for a few seconds. It replaces any unsent draft in that chat's message box.
- A fresh session loses the nuance of the old conversation; it can read the old transcript for details but won't by default.
- A resumed or fresh CLI run happens in the background; an open desktop window shows the new turns only after you reopen the chat.
- If the limit hasn't actually reset yet, the run fails and is not retried.

## Requirements

macOS 14 or later, the Swift toolchain (Xcode or Command Line Tools), and the `codex` and/or `claude` CLI. See [installation.md](installation.md).
