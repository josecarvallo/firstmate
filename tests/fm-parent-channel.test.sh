#!/usr/bin/env bash
# The parent escalation channel: a decision closes in the channel where it opened.
#
# A secondmate home and its parent home keep SEPARATE status logs. The mate
# escalates onto the parent's own log (state/<mate>.status under the parent
# home, or the mirrored parent-replies.status on a remote route), and that log
# is the only decision surface the parent's OPEN DECISIONS fold reads for that
# mate.
#
# The forensic failure these tests pin (2026-08-23, key
# wi812-codex-review-4-scope): the same key existed in TWO copies - opened by
# the mate in the parent channel, and opened by its worker in the worker's own
# local status - and the mate's answer closed only the worker's copy, because
# fm-send --resolve-key pointed at the WORKER. Neither copy knew about the
# other, so the parent's fold showed an answered, already-executed decision as
# open forever and the parent had to close it by hand. A second gap sat next to
# it: a mate-ORIGINATED escalation had no mechanism to reach the parent channel
# at all, because the only correlated-report helper demanded a corr= id that a
# self-raised decision has by contract.
#
# Chosen resolution: propagate the close to every live copy of the key. The
# parent's log is a real append-only stream that wake classification,
# crew-state, pending-reply resolution, and the open-decision fold all read
# directly; it cannot become a projection of some other owner without a new
# source of truth spanning two independent homes with no shared transaction.
# Propagation matches the existing grain instead - the close is already an
# append written by the answerer, and a serialized live-state append makes it
# safe under replay and key reuse.
#
# These tests drive the real executables and assert through the real consumer
# (fm-wake-drain.sh's OPEN DECISIONS section for the parent home), never
# through source text:
#   1. FULL CYCLE: the mate opens a keyed decision in the parent channel, the
#      parent sees it, the answer is sent pointing AT THE WORKER, and the
#      parent's fold comes out clean.
#   2. A mate-ORIGINATED escalation that nobody asked for reaches the parent
#      channel, with no corr= id.
#   3. A remote-route home escalates and closes onto its mirrored channel.
#   4. A primary home is untouched, and a secondmate home whose parent binding
#      is unreadable refuses loudly instead of closing only locally.
#   5. The reserved pending-reply-<id> namespace keeps its single owner: a
#      close aimed at it never propagates a foreign line into the parent
#      channel.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-parent-channel)

# Stub tmux so the submit path reaches a clean "empty" verdict, and stub sleep.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 1 ] && printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# A parent home plus a LOCAL-route secondmate home bound to it.
# Echoes "<parent-home> <mate-home>".
setup_pair() {  # <name> <mate-id>
  local base="$TMP_ROOT/$1-$RANDOM" parent mate id=$2
  parent="$base/parent"; mate="$base/mate"
  mkdir -p "$parent/state" "$parent/data" "$mate/state" "$mate/data"
  printf '%s\n' "$id" > "$mate/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=local\n'
    printf 'parent_home=%s\n' "$parent"
  } > "$mate/.fm-secondmate-parent"
  printf '%s %s\n' "$parent" "$mate"
}

drain_out() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" 2>/dev/null
}

run_send() {  # <fakebin> <home> <log> <fm-send args...>
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 1. The full cycle, exactly as it failed in the field.
# ---------------------------------------------------------------------------
test_full_cycle_close_reaches_parent_channel() {
  local dir fb log parent mate pair rc out
  dir="$TMP_ROOT/full-cycle"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  pair=$(setup_pair full-cycle amplifica)
  parent=${pair% *}; mate=${pair#* }

  # (a) The mate's worker raises a keyed decision in the mate's own home, and
  #     the mate escalates that same key onto the PARENT channel.
  fm_write_meta "$mate/state/wi812.meta" "window=sess:fm-wi812" "kind=ship"
  printf 'needs-decision [key=review-4-scope]: fix 24+25, defer 26/27/28?\n' \
    > "$mate/state/wi812.status"
  printf 'needs-decision [key=review-4-scope]: relaying my worker: fix 24+25, defer 26/27/28?\n' \
    > "$parent/state/amplifica.status"

  # (b) The parent sees it.
  out=$(drain_out "$parent")
  printf '%s' "$out" | grep -F '[key=review-4-scope]' >/dev/null \
    || fail "precondition: the escalated decision should list as open in the parent's fold: $out"

  # (c)+(d) The answer is sent pointing AT THE WORKER - the exact field case.
  run_send "$fb" "$mate" "$log" wi812 --resolve-key review-4-scope \
    "fix 24+25, defer 26/27/28"; rc=$?
  expect_code 0 "$rc" "answering the worker with --resolve-key should succeed"
  grep -F 'resolved [key=review-4-scope]' "$mate/state/wi812.status" >/dev/null \
    || fail "the worker's own copy was not closed: $(cat "$mate/state/wi812.status")"

  # (e) The parent's fold must come out clean. THIS is what regressed.
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=review-4-scope]' >/dev/null; then
    fail "the answered decision is STILL open in the parent's fold; the close never left the mate's home:"$'\n'"--- parent channel ---"$'\n'"$(cat "$parent/state/amplifica.status")"$'\n'"--- drain ---"$'\n'"$out"
  fi
  grep -F 'resolved [key=review-4-scope]' "$parent/state/amplifica.status" >/dev/null \
    || fail "no closing line reached the parent channel: $(cat "$parent/state/amplifica.status")"
  pass "parent channel: a close aimed at the worker also closes the key the mate opened upstream"
}

# Reopening a key is a new decision lifetime even when its answer repeats, while
# repeating a close against an already-closed lifetime remains a no-op.
test_reopened_key_closes_and_close_replay_is_idempotent() {
  local dir fb log parent mate pair rc n out
  dir="$TMP_ROOT/idem"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  pair=$(setup_pair idem beta)
  parent=${pair% *}; mate=${pair#* }

  fm_write_meta "$mate/state/w1.meta" "window=sess:fm-w1" "kind=ship"
  printf 'needs-decision [key=dup-guard]: a or b\n' > "$mate/state/w1.status"
  printf 'needs-decision [key=dup-guard]: a or b\n' > "$parent/state/beta.status"

  run_send "$fb" "$mate" "$log" w1 --resolve-key dup-guard "pick a"; rc=$?
  expect_code 0 "$rc" "the first answer should succeed"
  # Re-open both live copies and answer again with the same text.
  printf 'needs-decision [key=dup-guard]: a or b\n' >> "$mate/state/w1.status"
  printf 'needs-decision [key=dup-guard]: a or b\n' >> "$parent/state/beta.status"
  run_send "$fb" "$mate" "$log" w1 --resolve-key dup-guard "pick a"; rc=$?
  expect_code 0 "$rc" "the reopened decision should accept the repeated answer"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=dup-guard]' >/dev/null; then
    fail "the reopened decision stayed open after the repeated answer: $out"
  fi
  n=$(grep -c 'resolved \[key=dup-guard\]' "$parent/state/beta.status" || true)
  [ "$n" = 2 ] \
    || fail "two decision lifetimes should have two closes, found $n: $(cat "$parent/state/beta.status")"

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved --key dup-guard "pick a" >/dev/null 2>&1 \
    || fail "replaying an already-settled close should succeed"
  n=$(grep -c 'resolved \[key=dup-guard\]' "$parent/state/beta.status" || true)
  [ "$n" = 2 ] \
    || fail "an already-settled close replay appended a third line: $(cat "$parent/state/beta.status")"
  pass "parent channel: reopened keys close again, while settled close replays remain idempotent"
}

# ---------------------------------------------------------------------------
# 2. A mate-ORIGINATED escalation, with no corr= id, reaches the parent.
# ---------------------------------------------------------------------------
test_mate_originated_escalation_reaches_parent() {
  local dir parent mate pair rc out
  dir="$TMP_ROOT/originated"; mkdir -p "$dir"
  pair=$(setup_pair originated gamma)
  parent=${pair% *}; mate=${pair#* }

  # Nobody asked for this: no marked request, so no corr= id exists by contract.
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision --key money-risk \
    "review-26/27 look like real money leaving without its discount; decide before I touch them" \
    >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a mate-originated escalation should be deliverable without a corr id"

  grep -F '[key=money-risk]' "$parent/state/gamma.status" >/dev/null \
    || fail "the mate's own escalation never reached the parent channel: $(cat "$parent/state/gamma.status" 2>&1)"
  case "$(cat "$parent/state/gamma.status")" in
    *corr=*) fail "a self-raised escalation must not invent a correlation id" ;;
  esac

  out=$(drain_out "$parent")
  printf '%s' "$out" | grep -F '[key=money-risk]' >/dev/null \
    || fail "the escalation did not reach the parent's OPEN DECISIONS fold: $out"

  # And it closes through the same channel, so the pair is symmetric.
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate resolved --key money-risk "captain confirmed: scout it separately" \
    >/dev/null 2>&1 || fail "closing a self-raised escalation should succeed"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F '[key=money-risk]' >/dev/null; then
    fail "the self-raised escalation stayed open after its own close: $out"
  fi
  pass "parent channel: a self-raised escalation reaches the parent with no corr id, and closes there"
}

# ---------------------------------------------------------------------------
# 3. Remote route: the same two directions land on the mirrored channel.
# ---------------------------------------------------------------------------
test_remote_route_uses_mirrored_channel() {
  local dir mate rc
  dir="$TMP_ROOT/remote-route"; mkdir -p "$dir/state"
  mate="$dir"
  printf 'delta\n' > "$mate/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\n'
    printf 'route=remote\n'
  } > "$mate/.fm-secondmate-parent"

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate blocked --key vpn-down "cannot reach the forge" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a remote-route escalation should succeed"
  grep -F '[key=vpn-down]' "$mate/state/parent-replies.status" >/dev/null \
    || fail "a remote-route escalation must land on the mirrored channel: $(ls "$mate/state")"
  [ ! -e "$mate/state/delta.status" ] \
    || fail "a remote-route escalation must not write a local task log"
  pass "parent channel: a remote route escalates onto its mirrored channel, not a local log"
}

# ---------------------------------------------------------------------------
# 4. A primary home is untouched; an unreadable binding fails visibly.
# ---------------------------------------------------------------------------
test_primary_home_unaffected_and_broken_binding_refuses() {
  local dir fb log home rc err mate pair parent out
  dir="$TMP_ROOT/edges"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"

  # A primary home has no parent channel: the close is purely local, unchanged.
  home="$dir/primary"; mkdir -p "$home/state"
  fm_write_meta "$home/state/p1.meta" "window=sess:fm-p1" "kind=ship"
  printf 'needs-decision [key=plain]: a or b\n' > "$home/state/p1.status"
  run_send "$fb" "$home" "$log" p1 --resolve-key plain "a"; rc=$?
  expect_code 0 "$rc" "a primary home's answer must keep working exactly as before"
  out=$(drain_out "$home")
  if printf '%s' "$out" | grep -F '[key=plain]' >/dev/null; then
    fail "a primary home's own close regressed: $out"
  fi

  # A secondmate home whose parent binding is unreadable must refuse rather
  # than close only locally and strand the upstream copy in silence.
  pair=$(setup_pair broken epsilon)
  parent=${pair% *}; mate=${pair#* }
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nroute=local\n' \
    > "$mate/.fm-secondmate-parent"
  fm_write_meta "$mate/state/w2.meta" "window=sess:fm-w2" "kind=ship"
  printf 'needs-decision [key=stranded]: a or b\n' > "$mate/state/w2.status"
  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" w2 --resolve-key stranded "a" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] \
    || fail "an unresolvable parent channel must refuse, not close only locally"
  assert_contains "$(cat "$err")" "parent" "the refusal should name the parent channel"
  [ ! -s "$log" ] || fail "the refused send still typed text: $(cat "$log")"
  if grep -F 'resolved' "$mate/state/w2.status" >/dev/null; then
    fail "the refused send still closed the local copy: $(cat "$mate/state/w2.status")"
  fi
  [ -n "$parent" ] || fail "unreachable"
  pass "parent channel: a primary home is unchanged, and an unreadable binding refuses before sending"
}

# A symlinked parent channel is the quiet version of the same failure: the fold
# refuses to read one, so it reports "no open keys" and a caller that trusted
# only the fold would close its local copy and strand the upstream one.
test_symlinked_parent_channel_refuses() {
  local dir fb log parent mate pair rc err
  dir="$TMP_ROOT/symlink"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"
  pair=$(setup_pair symlink eta)
  parent=${pair% *}; mate=${pair#* }

  printf 'needs-decision [key=sneaky]: a or b\n' > "$dir/elsewhere.status"
  ln -s "$dir/elsewhere.status" "$parent/state/eta.status"
  fm_write_meta "$mate/state/w4.meta" "window=sess:fm-w4" "kind=ship"
  printf 'needs-decision [key=sneaky]: a or b\n' > "$mate/state/w4.status"

  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" w4 --resolve-key sneaky "a" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked parent channel must refuse, not close only locally"
  [ ! -s "$log" ] || fail "the refused send still typed text: $(cat "$log")"
  if grep -F 'resolved' "$dir/elsewhere.status" >/dev/null; then
    fail "the close followed a symlink out of the parent's state dir"
  fi
  pass "parent channel: a symlinked channel refuses instead of silently stranding the upstream copy"
}

# The identity marker's strictness is a protection, not a convenience: a marker
# carrying more than one line is corrupt, and routing on line one would guess at
# which home this is instead of surfacing the corruption.
test_corrupt_identity_marker_refuses() {
  local dir parent mate pair marker
  dir="$TMP_ROOT/corrupt-marker"; mkdir -p "$dir"
  pair=$(setup_pair corrupt-marker theta)
  parent=${pair% *}; mate=${pair#* }
  marker="$mate/.fm-secondmate-home"

  for bad in 'theta
iota' '../parent' 'has space'; do
    printf '%s\n' "$bad" > "$marker"
    if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
        "$REPORT" --escalate blocked --key corrupt "routing on a corrupt marker" \
        >/dev/null 2>&1; then
      fail "a corrupt identity marker still routed an escalation: $(printf '%s' "$bad" | tr '\n' '/')"
    fi
  done
  [ ! -e "$parent/state/theta.status" ] \
    || fail "a corrupt marker still wrote into the parent home: $(cat "$parent/state/theta.status")"

  # And the well-formed single-line marker still routes, so the check is strict
  # rather than simply broken.
  printf 'theta\n' > "$marker"
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate blocked --key corrupt "now it routes" >/dev/null 2>&1 \
    || fail "a well-formed marker should still route"
  grep -F '[key=corrupt]' "$parent/state/theta.status" >/dev/null \
    || fail "the well-formed marker did not reach the parent channel"
  pass "parent channel: a corrupt identity marker refuses, a well-formed one still routes"
}

test_parent_evidence_without_identity_refuses() {
  local dir fb log err parent mate pair rc
  dir="$TMP_ROOT/missing-marker"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; err="$dir/err.log"
  pair=$(setup_pair missing-marker iota)
  parent=${pair% *}; mate=${pair#* }

  fm_write_meta "$mate/state/w5.meta" "window=sess:fm-w5" "kind=ship"
  printf 'needs-decision [key=upstream]: a or b\n' > "$mate/state/w5.status"
  printf 'needs-decision [key=upstream]: a or b\n' > "$parent/state/iota.status"
  rm -f "$mate/.fm-secondmate-home"

  : > "$log"
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" w5 --resolve-key upstream "a" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a parent binding without an identity marker was treated as a primary home"
  assert_contains "$(cat "$err")" "cannot be resolved" "the missing identity must be classified as an unresolvable parent channel"
  [ ! -s "$log" ] || fail "the missing-identity send still typed text: $(cat "$log")"
  if grep -F 'resolved' "$mate/state/w5.status" >/dev/null; then
    fail "the missing-identity send closed only the local copy"
  fi

  mv "$mate/.fm-secondmate-parent" "$mate/parent-binding-record"
  ln -s "$mate/parent-binding-record" "$mate/.fm-secondmate-parent"
  if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      "$REPORT" --escalate blocked --key upstream "still waiting" \
      >/dev/null 2>"$err"; then
    fail "symlinked parent evidence without an identity marker was treated as no parent"
  fi
  assert_contains "$(cat "$err")" "cannot be resolved" "symlinked parent evidence must remain unresolvable"
  pass "parent channel: any parent evidence without a usable identity fails visibly"
}

test_long_key_metadata_survives_and_closes() {
  local dir fb log parent mate pair rc out long_key long_note line_len
  dir="$TMP_ROOT/long-key"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  pair=$(setup_pair long-key kappa)
  parent=${pair% *}; mate=${pair#* }
  long_key=$(printf 'k%.0s' {1..175})
  long_note=$(printf 'n%.0s' {1..240})

  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
    "$REPORT" --escalate needs-decision --key "$long_key" "$long_note" \
    >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a key that fits with intact metadata should be accepted"
  grep -F "[key=$long_key]" "$parent/state/kappa.status" >/dev/null \
    || fail "the long opening key was truncated: $(cat "$parent/state/kappa.status")"
  line_len=$(awk 'NR == 1 { print length($0) }' "$parent/state/kappa.status")
  [ "$line_len" -le 220 ] || fail "the capped escalation exceeded 220 characters: $line_len"

  fm_write_meta "$mate/state/w6.meta" "window=sess:fm-w6" "kind=ship"
  printf 'needs-decision [key=%s]: local copy\n' "$long_key" > "$mate/state/w6.status"
  run_send "$fb" "$mate" "$log" w6 --resolve-key "$long_key" "closed"; rc=$?
  expect_code 0 "$rc" "the intact long key should remain closeable by its original value"
  grep -F "resolved [key=$long_key]" "$parent/state/kappa.status" >/dev/null \
    || fail "the long closing key was truncated: $(cat "$parent/state/kappa.status")"
  out=$(drain_out "$parent")
  if printf '%s' "$out" | grep -F "[key=$long_key]" >/dev/null; then
    fail "the long key remained open after resolving it with the original value: $out"
  fi
  pass "parent channel: long decision keys preserve metadata and remain closeable"
}

# ---------------------------------------------------------------------------
# 5. The reserved pending-reply-<id> namespace keeps its single owner.
# ---------------------------------------------------------------------------
test_reserved_namespace_is_not_propagated() {
  local dir fb log parent mate pair rc
  dir="$TMP_ROOT/reserved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  pair=$(setup_pair reserved zeta)
  parent=${pair% *}; mate=${pair#* }

  # The parent's own library raised this one in the parent channel and is the
  # only thing that may close it.
  printf 'needs-decision [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=x\n' \
    > "$parent/state/zeta.status"
  fm_write_meta "$mate/state/w3.meta" "window=sess:fm-w3" "kind=ship"
  printf 'needs-decision [key=pending-reply-abcdef0123456789]: pending-reply-missed: task=x\n' \
    > "$mate/state/w3.status"

  run_send "$fb" "$mate" "$log" w3 --resolve-key pending-reply-abcdef0123456789 "answered"
  rc=$?
  expect_code 0 "$rc" "the existing reserved-key send behavior must not change"
  if grep -F 'answered' "$parent/state/zeta.status" >/dev/null; then
    fail "a foreign close was propagated into the reserved namespace's channel: $(cat "$parent/state/zeta.status")"
  fi
  # The mate-originated helper must refuse the reserved namespace outright.
  if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      "$REPORT" --escalate needs-decision --key pending-reply-abcdef0123456789 "mine now" \
      >/dev/null 2>&1; then
    fail "the escalation helper claimed a reserved key namespace"
  fi
  if env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$mate" \
      "$REPORT" --escalate needs-decision --key pending-reply-abcdef0123456789 \
      "pending-reply-missed: task=x" >/dev/null 2>&1; then
    fail "owner-like caller text bypassed the reserved key namespace"
  fi
  pass "parent channel: the reserved pending-reply namespace keeps its single owner"
}

test_full_cycle_close_reaches_parent_channel
test_reopened_key_closes_and_close_replay_is_idempotent
test_mate_originated_escalation_reaches_parent
test_remote_route_uses_mirrored_channel
test_primary_home_unaffected_and_broken_binding_refuses
test_symlinked_parent_channel_refuses
test_corrupt_identity_marker_refuses
test_parent_evidence_without_identity_refuses
test_long_key_metadata_survives_and_closes
test_reserved_namespace_is_not_propagated
