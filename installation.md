# Installation

Instructions for an agent (or a person) installing ContinueTimer on a Mac. Run the steps in order and stop at the first failed check. Steps marked **(user)** need a human; ask the user to do them and wait for confirmation.

## 1. Check prerequisites

```bash
sw_vers -productVersion          # must be 14.0 or later
xcrun --find swiftc              # must print a path
zsh -lc 'command -v codex; command -v claude'
```

- macOS older than 14: stop; the app can't run.
- `swiftc` not found: run `xcode-select --install` **(user)**: a dialog asks them to install the Command Line Tools. Re-check afterwards.
- At least one of `codex` / `claude` must be found. The app runs them through a login shell (`zsh -l`), so they must be on the PATH there, not only in the agent's shell. Neither found: tell the user, since the app has nothing to resume.

## 2. Get the source

If you are not already in a clone of this repository:

```bash
git clone https://github.com/lassehalle/ContinueTimer.git ~/ContinueTimer
cd ~/ContinueTimer
```

(Private repository: cloning needs a GitHub account with access, e.g. via `gh auth login`.)

## 3. Build

```bash
./build.sh
```

Expect the last line `Built …/ContinueTimer.app`. This compiles `ContinueTimer.swift` into an ad-hoc signed app bundle next to the script.

## 4. Install and launch

```bash
osascript -e 'quit app id "local.continuetimer"' 2>/dev/null || true   # stop an older copy
mkdir -p ~/Applications
rm -rf ~/Applications/ContinueTimer.app
cp -R ContinueTimer.app ~/Applications/
open ~/Applications/ContinueTimer.app
sleep 2 && pgrep -fl 'ContinueTimer.app/Contents/MacOS/ContinueTimer'
```

`pgrep` must print one process. The app has no Dock icon; it appears as ⏱ in the menu bar.

## 5. Grant Accessibility (user, needed for Codex)

Only needed to deliver to Codex chats that are open in the ChatGPT/Codex desktop app, but recommended.

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```

Ask the user to switch on **ContinueTimer** in that list (add it with **+** from `~/Applications` if missing). Then restart the app so it picks up the permission:

```bash
osascript -e 'quit app id "local.continuetimer"'; sleep 1; open ~/Applications/ContinueTimer.app
```

## 6. Start at login (optional, user)

Ask the user whether ContinueTimer should start automatically. If yes, they add `~/Applications/ContinueTimer.app` under System Settings → General → Login Items.

## 7. Done: tell the user

- Click ⏱ in the menu bar to schedule a timer.
- Logs: `~/Library/Logs/ContinueTimer/`.
- The first Codex timer may trigger the Accessibility prompt if step 5 was skipped.

## Updating

```bash
git pull
./build.sh
```

Then repeat step 4. Each rebuild changes the ad-hoc signature, so macOS drops the Accessibility permission: repeat step 5 (the user switches ContinueTimer off and on again).

## Uninstalling

```bash
osascript -e 'quit app id "local.continuetimer"'
rm -rf ~/Applications/ContinueTimer.app ~/Library/Logs/ContinueTimer
defaults delete local.continuetimer
```

Also remove it from Accessibility and Login Items if it was added.
