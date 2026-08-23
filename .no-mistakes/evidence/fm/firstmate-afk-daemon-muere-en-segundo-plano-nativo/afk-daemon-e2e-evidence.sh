#!/usr/bin/env bash
set -u

ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-evidence.XXXXXX")
CAPTAIN_SESSION="fm-afk-evidence-captain-$$"
FOREIGN_PID=""

cleanup() {
  if [ -n "$FOREIGN_PID" ]; then
    kill "$FOREIGN_PID" 2>/dev/null || true
    wait "$FOREIGN_PID" 2>/dev/null || true
  fi
  tmux kill-session -t "$CAPTAIN_SESSION" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

yesno() {
  if "$@"; then printf 'yes\n'; else printf 'no\n'; fi
}

printf 'SCENARIO 1 — unsupported native entries refuse before writing away state\n'
mkdir -p "$LAB/native/state"
native_out=$(FM_HOME="$LAB/native" FM_STATE_OVERRIDE="$LAB/native/state" \
  FM_AFK_STATE_PREPARED=1 "$ROOT/bin/fm-afk-start.sh" 2>&1)
native_rc=$?
printf 'direct entry rc=%s\n%s\n' "$native_rc" "$native_out"
printf 'direct entry wrote .afk: '
yesno test -e "$LAB/native/state/.afk"

launch_native_out=$(FM_HOME="$LAB/native" FM_STATE_OVERRIDE="$LAB/native/state" \
  "$ROOT/bin/fm-afk-launch.sh" start-native 2>&1)
launch_native_rc=$?
printf 'start-native rc=%s\n%s\n' "$launch_native_rc" "$launch_native_out"
printf 'start-native wrote terminal record: '
yesno test -e "$LAB/native/state/.afk-daemon-terminal"

printf '\nSCENARIO 2 — supported start owns a real detached tmux terminal\n'
mkdir -p "$LAB/supported/state"
tmux new-session -d -s "$CAPTAIN_SESSION"
CAPTAIN_PANE=$(tmux display-message -p -t "$CAPTAIN_SESSION" '#{pane_id}')
PANES_BEFORE=$(tmux list-panes -t "$CAPTAIN_SESSION" | wc -l | tr -d ' ')
supported_out=$(FM_HOME="$LAB/supported" FM_STATE_OVERRIDE="$LAB/supported/state" \
  FM_SUPERVISOR_TARGET="$CAPTAIN_PANE" FM_SUPERVISOR_BACKEND=tmux \
  "$ROOT/bin/fm-afk-launch.sh" start 2>&1)
supported_rc=$?
TERMINAL_BACKEND=$(cut -f1 "$LAB/supported/state/.afk-daemon-terminal" 2>/dev/null || true)
TERMINAL_TARGET=$(cut -f2 "$LAB/supported/state/.afk-daemon-terminal" 2>/dev/null || true)
PANES_AFTER=$(tmux list-panes -t "$CAPTAIN_SESSION" | wc -l | tr -d ' ')
printf 'supported start rc=%s\n%s\n' "$supported_rc" "$supported_out"
printf 'recorded backend=%s\n' "$TERMINAL_BACKEND"
printf 'detached terminal alive after launcher returned: '
yesno tmux has-session -t "$TERMINAL_TARGET"
printf 'captain pane count unchanged: %s -> %s\n' "$PANES_BEFORE" "$PANES_AFTER"
FM_HOME="$LAB/supported" FM_STATE_OVERRIDE="$LAB/supported/state" \
  "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1
printf 'stop removed exact detached terminal: '
if tmux has-session -t "$TERMINAL_TARGET" 2>/dev/null; then printf 'no\n'; else printf 'yes\n'; fi
printf 'stop cleared .afk and terminal record: '
if [ ! -e "$LAB/supported/state/.afk" ] && [ ! -e "$LAB/supported/state/.afk-daemon-terminal" ]; then
  printf 'yes\n'
else
  printf 'no\n'
fi

printf '\nSCENARIO 3 — a same-named daemon from another home is not this home\047s daemon\n'
mkdir -p "$LAB/current/state/.supervise-daemon.lock" "$LAB/foreign/bin"
printf '#!/usr/bin/env bash\nwhile :; do sleep 0.2; done\n' > "$LAB/foreign/bin/fm-supervise-daemon.sh"
chmod +x "$LAB/foreign/bin/fm-supervise-daemon.sh"
"$LAB/foreign/bin/fm-supervise-daemon.sh" &
FOREIGN_PID=$!
printf '%s' "$FOREIGN_PID" > "$LAB/current/state/.supervise-daemon.lock/pid"
date +%s > "$LAB/current/state/.afk"
foreign_out=$(FM_HOME="$LAB/current" FM_STATE_OVERRIDE="$LAB/current/state" \
  "$ROOT/bin/fm-afk-launch.sh" stop 2>&1)
foreign_rc=$?
printf 'stop rc=%s\n%s\n' "$foreign_rc" "$foreign_out"
printf 'foreign same-named process still alive: '
yesno kill -0 "$FOREIGN_PID"
printf 'this home recorded missing supervision: '
yesno test -e "$LAB/current/state/.afk-daemon-died-unexpectedly"
kill "$FOREIGN_PID" 2>/dev/null || true
wait "$FOREIGN_PID" 2>/dev/null || true
FOREIGN_PID=""

printf '\nSCENARIO 4 — out-of-band SIGTERM becomes catch-up evidence and is consumed after publication\n'
mkdir -p "$LAB/death/state/.supervise-daemon.lock"
date +%s > "$LAB/death/state/.afk"
bash -c 'while :; do sleep 0.2; done' &
DEAD_PID=$!
printf '%s' "$DEAD_PID" > "$LAB/death/state/.supervise-daemon.lock/pid"
( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$DEAD_PID" > "$LAB/death/state/.supervise-daemon.lock/pid-identity" )
registered_before=$(FM_HOME="$LAB/death" FM_STATE_OVERRIDE="$LAB/death/state" \
  bash -c '. "$1"; daemon_lock_held_by_live_daemon && printf yes || printf no' _ "$ROOT/bin/fm-afk-start.sh")
printf 'registered as live before external SIGTERM: %s\n' "$registered_before"
kill -TERM "$DEAD_PID"
wait "$DEAD_PID" 2>/dev/null || true
death_out=$(FM_HOME="$LAB/death" FM_STATE_OVERRIDE="$LAB/death/state" \
  "$ROOT/bin/fm-afk-launch.sh" stop 2>&1)
death_rc=$?
printf 'stop after external SIGTERM rc=%s\n%s\n' "$death_rc" "$death_out"
printf 'durable death marker exists before return: '
yesno test -e "$LAB/death/state/.afk-daemon-died-unexpectedly"
return_out=$(FM_HOME="$LAB/death" FM_STATE_OVERRIDE="$LAB/death/state" \
  "$ROOT/bin/fm-afk-return.sh" begin 2>&1)
return_rc=$?
printf 'return rc=%s\n%s\n' "$return_rc" "$return_out"
printf 'death marker consumed after catch-up publication: '
if [ ! -e "$LAB/death/state/.afk-daemon-died-unexpectedly" ]; then printf 'yes\n'; else printf 'no\n'; fi
printf 'ordinary work cleared: '
if [ ! -e "$LAB/death/state/.afk-return-catchup" ]; then printf 'yes\n'; else printf 'no\n'; fi
