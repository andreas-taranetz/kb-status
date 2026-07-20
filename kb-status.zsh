# ── Keyboard status (ZSA Voyager LEDs) ──────────────────────────────
#
# Distributes keyboard columns across registered terminal tabs:
#   1 tab  → whole keyboard
#   2 tabs → left half / right half
#   3 tabs → ~3 columns each, etc.
#
# Columns re-distribute automatically as tabs open and close.
#
# LED colors:
#   white fill  — new tab joined (join animation, ~1.5 s)
#   cyan fill   — command running in that tab
#   solid green — last command exited 0 (success, clears after 5 s)
#   solid red   — last command exited non-zero (failure, clears after 5 s)
#   orange      — Claude is thinking (UserPromptSubmit hook)
#   blue        — Claude finished, waiting for input (Stop hook)
#   amber blink — Claude needs attention (Notification hook)
#
# Setup:
#   1. Daemon auto-starts via launchd — ~/Library/LaunchAgents/com.user.kb-status.plist
#   2. Daemon script: ~/.local/bin/kb-status (requires /opt/homebrew/bin/python3 + hidapi)
#   3. /opt/homebrew/bin/python3 must be in System Settings → Privacy → Input Monitoring
#   4. Each new tab auto-registers on startup. Override with: kbtab <N>
#
# Troubleshoot:
#   launchctl list | grep kb-status   — check daemon is running (exit code 0 = healthy)
#   cat /tmp/kb-status.log            — daemon logs
#   echo "busy 1" | nc -U ~/.local/run/kb-status.sock   — manual test

_KB_SOCKET="$HOME/.local/run/kb-status.sock"
_KB_TAB_DIR="$HOME/.local/run/kb-tabs"
_KB_TAB=""
_kb_skip_precmd=0

_kb_send() { [[ -S "$_KB_SOCKET" ]] && printf '%s\n' "$*" | nc -U "$_KB_SOCKET" 2>/dev/null &! }

# kbtab [N] — assign this shell to keyboard slot N (0-9), or auto-assign if omitted
kbtab() {
    local n=$1
    mkdir -p "$_KB_TAB_DIR"
    if [[ -z "$n" ]]; then
        # Auto-assign: pick lowest slot whose PID file is absent or stale
        for n in 1 2 3 4 5 6 7 8 9 0; do
            local pidfile="$_KB_TAB_DIR/$n"
            if [[ -f "$pidfile" ]]; then
                local pid=$(cat "$pidfile" 2>/dev/null)
                kill -0 "$pid" 2>/dev/null && continue   # slot live, skip
                rm -f "$pidfile"                          # stale, reclaim
            fi
            break
        done
    elif [[ ! "$n" =~ ^[0-9]$ ]]; then
        echo "usage: kbtab [0-9]" >&2; return 1
    fi
    if [[ -n "$_KB_TAB" && "$_KB_TAB" != "$n" ]]; then
        [[ -S "$_KB_SOCKET" ]] && printf 'unregister %s\n' "$_KB_TAB" | nc -U "$_KB_SOCKET" 2>/dev/null
        rm -f "$_KB_TAB_DIR/$_KB_TAB"
    fi
    echo $$ > "$_KB_TAB_DIR/$n"
    export _KB_TAB=$n
    _kb_skip_precmd=1   # suppress the first precmd so join animation isn't overwritten
    _kb_send "register $n"
}
kbtab   # auto-assign on shell startup

autoload -Uz add-zsh-hook

_kb_preexec() {
    local cmd="${1%% *}"
    # Skip shell-busy signal for commands that manage their own LED state
    case "$cmd" in
        claude|cr|c|kbtab|exit|q) _kb_skip_precmd=1; return ;;
    esac
    _kb_skip_precmd=0
    [[ -n "$_KB_TAB" ]] && _kb_send "busy $_KB_TAB"
}
_kb_precmd() {
    local rc=$?
    if (( _kb_skip_precmd )); then _kb_skip_precmd=0; return; fi
    [[ -n "$_KB_TAB" ]] && _kb_send "done $_KB_TAB $rc"
}

add-zsh-hook preexec _kb_preexec
add-zsh-hook precmd  _kb_precmd

zshexit() {
    if [[ -n "$_KB_TAB" ]]; then
        # Synchronous — no &! since we're exiting
        [[ -S "$_KB_SOCKET" ]] && printf 'unregister %s\n' "$_KB_TAB" | nc -U "$_KB_SOCKET" 2>/dev/null
        rm -f "$_KB_TAB_DIR/$_KB_TAB"
    fi
}

# kbwhere — show which keyboard columns are assigned to this tab, and flash them
kbwhere() {
    [[ -z "$_KB_TAB" ]] && { echo "not registered (run kbtab)" >&2; return 1; }

    # Collect live registered tabs (same logic as daemon's _compute_allocations)
    local -a live=()
    for f in "$_KB_TAB_DIR"/*(N); do
        local pid=$(cat "$f" 2>/dev/null)
        kill -0 "$pid" 2>/dev/null && live+=( ${f:t} )
    done
    live=( ${(on)live} )  # sort numerically — must match daemon sort order
    local n=${#live} total=10
    local -a cols=(1 2 3 4 5 6 7 8 9 0)

    local pos=0
    for (( i=1; i<=n; i++ )); do
        [[ "${live[$i]}" == "$_KB_TAB" ]] && pos=$(( i-1 )) && break
    done

    local start=$(( pos * total / n ))
    local end=$(( (pos+1) * total / n ))
    local width=$(( end - start ))
    local first=${cols[$((start+1))]} last=${cols[$end]}

    echo "slot $_KB_TAB · columns $first–$last ($width/$total) · $n tab(s) registered"

    # Flash the columns: busy shows cyan fill, done clears after 2 s
    printf 'busy %s\n' "$_KB_TAB" | nc -U "$_KB_SOCKET" 2>/dev/null
    { sleep 2; printf 'done %s 0\n' "$_KB_TAB" | nc -U "$_KB_SOCKET" 2>/dev/null; } &!
}

# kbreset — clear all LEDs, drop all registrations, restart daemon
kbreset() {
    rm -f "$_KB_TAB_DIR"/*(N)
    export _KB_TAB=""
    _kb_send "reset"
    sleep 0.2
    launchctl unload ~/Library/LaunchAgents/com.user.kb-status.plist 2>/dev/null
    launchctl load  ~/Library/LaunchAgents/com.user.kb-status.plist
    echo "kb-status restarted"
}
