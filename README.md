# kb-status

ZSA Voyager keyboard LED status indicator for macOS terminal tabs.

Lights up columns of your keyboard to reflect what's happening in each terminal tab — commands running, success/failure, and Claude Code state — all without modifying keyboard firmware.

> **Note:** This currently only works with the [ZSA Voyager](https://www.zsa.io/voyager). It communicates over the Oryx HID protocol (USB usage page `0xFF60`) which is specific to ZSA keyboards running their stock firmware.

## How it works

A background daemon speaks the Oryx protocol over USB HID to control the RGB matrix directly. Shell hooks (`preexec`/`precmd`) and Claude Code hooks report tab state to the daemon over a Unix socket. No firmware changes required.

The keyboard columns are distributed across registered terminal tabs:

| Tabs open | Layout |
|-----------|--------|
| 1 | whole keyboard |
| 2 | left half / right half |
| 3 | ~3 columns each |
| 4 | ~2–3 columns each |
| … | continues dividing |

Columns re-distribute automatically as tabs open and close.

### LED colors

| Color | Meaning |
|-------|---------|
| White fill (bottom→top) | New terminal tab joined |
| Cyan fill (bottom→top) | Command running |
| Solid green | Last command exited 0 — clears after 5 s |
| Solid red | Last command exited non-zero — clears after 5 s |
| Solid orange | Claude Code is thinking |
| Solid blue | Claude Code waiting for input |
| Amber fast blink | Claude Code needs attention |

## Files

| File | Purpose |
|------|---------|
| `kb-status` | Python daemon — Oryx HID, LED animation loop, Unix socket server |
| `kb-status.zsh` | Zsh integration — shell hooks, `kbtab`, `kbwhere`, `kbreset` |
| `kb-claude-busy` | Hook script — sent by Claude Code on `UserPromptSubmit` |
| `kb-claude-wait` | Hook script — sent by Claude Code on `Stop` |
| `kb-claude-alert` | Hook script — sent by Claude Code on `Notification` |
| `kb-claude-idle` | Hook script — sent by Claude Code on `SessionEnd` |

## Requirements

- macOS
- ZSA Voyager with stock firmware (Oryx protocol)
- Python 3 via Homebrew: `/opt/homebrew/bin/python3`
- `hidapi` Python package: `pip3 install hidapi`
- `/opt/homebrew/bin/python3` added to **System Settings → Privacy & Security → Input Monitoring**

## Setup

### 1. Install the Python dependency

```sh
pip3 install hidapi
```

### 2. Source the shell integration

Add to your `~/.zshrc`:

```zsh
source ~/projects/kb-status/kb-status.zsh
```

### 3. Register the daemon with launchd

Create `~/Library/LaunchAgents/com.user.kb-status.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.kb-status</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/YOUR_USERNAME/projects/kb-status/kb-status</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/kb-status.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/kb-status.log</string>
</dict>
</plist>
```

Then load it:

```sh
launchctl load ~/Library/LaunchAgents/com.user.kb-status.plist
```

### 4. Grant Input Monitoring permission

Open **System Settings → Privacy & Security → Input Monitoring** and add `/opt/homebrew/bin/python3`.

### 5. Wire up Claude Code hooks (optional)

Add to `~/.claude/settings.json`:

```json
"hooks": {
  "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/path/to/kb-status/kb-claude-busy"}]}],
  "Stop":             [{"hooks": [{"type": "command", "command": "/path/to/kb-status/kb-claude-wait"}]}],
  "Notification":     [{"hooks": [{"type": "command", "command": "/path/to/kb-status/kb-claude-alert"}]}],
  "SessionEnd":       [{"hooks": [{"type": "command", "command": "/path/to/kb-status/kb-claude-idle"}]}]
}
```

## Shell commands

| Command | Description |
|---------|-------------|
| `kbtab [N]` | Manually assign this shell to slot N (0–9). Without argument, auto-assigns the next free slot. Runs automatically on shell startup. |
| `kbwhere` | Print which columns are assigned to this tab and flash them cyan for 2 s. |
| `kbreset` | Clear all registrations, turn off all LEDs, restart the daemon. |

## Troubleshooting

```sh
# Check daemon is running (exit code 0 = healthy)
launchctl list | grep kb-status

# View daemon logs
cat /tmp/kb-status.log

# Manual test
echo "busy 1" | nc -U ~/.local/run/kb-status.sock
```

If you see `open failed` in the logs, the Input Monitoring permission is missing or needs to be toggled off and back on.

If the keyboard stops responding to LED commands after an unclean shutdown, unplug and replug it to clear stale HID handles.
