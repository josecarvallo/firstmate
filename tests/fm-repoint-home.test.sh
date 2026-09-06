#!/usr/bin/env bash
# Tests for bin/fm-repoint-home.sh: reversible, per-home remote re-pointing
# between the original-as-origin and fork-as-source conventions.
#
# The guarantees under test:
#   - status is read-only and reports the layout and update source.
#   - a dry run (no --apply) mutates nothing; --apply performs the rename/add.
#   - to-fork produces origin=<fork>, upstream=<original>; to-origin reverses it
#     exactly (round-trip returns the identical remote set).
#   - re-pointing never touches the working tree, commits, or unlanded work.
#   - unexpected/ambiguous remote states fail closed (exit 2).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REPOINT="$ROOT/bin/fm-repoint-home.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-repoint-tests)

# A home in the original-as-origin layout: origin -> original.git, fork -> fork.git,
# checked out on main with one commit.
new_home() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w"
  git init -q --bare "$w/original.git"
  git -C "$w/original.git" symbolic-ref HEAD refs/heads/main
  git init -q --bare "$w/fork.git"
  git clone -q "$w/original.git" "$w/home" 2>/dev/null
  printf 'A\n' > "$w/home/f"
  git -C "$w/home" add -A
  git -C "$w/home" commit -qm A
  git -C "$w/home" push -q origin main
  git -C "$w/home" remote add fork "$w/fork.git"
  printf '%s\n' "$w"
}

run() { "$REPOINT" "$@" 2>&1; }
url() { git -C "$1" remote get-url "$2" 2>/dev/null || echo MISSING; }

test_status_reports_layout() {
  local w out
  w=$(new_home st)
  out=$(run status "$w/home")
  assert_contains "$out" "layout: original-as-origin" "status names the current layout"
  assert_contains "$out" "update source: origin" "status shows the resolved update source"
  pass "status reports layout and update source read-only"
}

test_dry_run_mutates_nothing() {
  local w out before_o before_f
  w=$(new_home dry)
  before_o=$(url "$w/home" origin); before_f=$(url "$w/home" fork)
  out=$(run to-fork "$w/home")
  assert_contains "$out" "dry run" "dry run announced"
  assert_contains "$out" "remote rename origin upstream" "dry run prints the exact commands"
  [ "$(url "$w/home" origin)" = "$before_o" ] || fail "dry run changed origin"
  [ "$(url "$w/home" fork)" = "$before_f" ] || fail "dry run changed fork"
  pass "dry run prints commands and mutates nothing"
}

test_to_fork_and_roundtrip() {
  local w orig_url fork_url head_before
  w=$(new_home rt)
  orig_url=$(url "$w/home" origin); fork_url=$(url "$w/home" fork)
  head_before=$(git -C "$w/home" rev-parse HEAD)

  run to-fork "$w/home" --apply >/dev/null
  [ "$(url "$w/home" origin)" = "$fork_url" ] || fail "origin is not the fork after to-fork"
  [ "$(url "$w/home" upstream)" = "$orig_url" ] || fail "upstream is not the original after to-fork"
  [ "$(url "$w/home" fork)" = MISSING ] || fail "a stale fork remote survived to-fork"
  # Working tree and HEAD are untouched by a remote re-point.
  [ "$(git -C "$w/home" rev-parse HEAD)" = "$head_before" ] || fail "HEAD moved during re-point"

  run to-origin "$w/home" --apply >/dev/null
  [ "$(url "$w/home" origin)" = "$orig_url" ] || fail "origin not restored to the original after to-origin"
  [ "$(url "$w/home" fork)" = "$fork_url" ] || fail "fork not restored after to-origin"
  [ "$(url "$w/home" upstream)" = MISSING ] || fail "a stale upstream remote survived to-origin"
  pass "to-fork then to-origin is an exact reversible round-trip"
}

test_idempotent_to_fork() {
  local w out
  w=$(new_home idem)
  run to-fork "$w/home" --apply >/dev/null
  out=$(run to-fork "$w/home" --apply)
  assert_contains "$out" "already fork-as-source" "second to-fork is a no-op"
  pass "to-fork is idempotent"
}

test_unexpected_state_fails_closed() {
  local w out rc
  w=$(new_home bad)
  git -C "$w/home" remote add upstream "$w/original.git"  # ambiguous: both fork and upstream
  out=$(run to-fork "$w/home"); rc=$?
  [ "$rc" -eq 2 ] || fail "ambiguous state did not fail closed (rc=$rc)"
  assert_contains "$out" "unexpected state" "ambiguous state named"
  pass "an unexpected remote state fails closed rather than guessing"
}

test_no_fork_remote_requires_url() {
  local w out rc
  w=$(new_home nofork)
  git -C "$w/home" remote remove fork
  out=$(run to-fork "$w/home"); rc=$?
  [ "$rc" -eq 2 ] || fail "missing fork url did not fail closed (rc=$rc)"
  assert_contains "$out" "pass --fork-url" "missing fork url is reported"
  # With an explicit fork url it proceeds (dry run).
  out=$(run to-fork "$w/home" --fork-url "$w/fork.git")
  assert_contains "$out" "dry run" "explicit --fork-url lets it proceed"
  pass "to-fork needs a fork url when there is no fork remote"
}

test_fork_url_ignored_when_fork_remote_present() {
  local w out fork_url bogus
  w=$(new_home forkurl)
  fork_url=$(url "$w/home" fork)
  bogus="$w/bogus.git"
  out=$(run to-fork "$w/home" --fork-url "$bogus" --apply)
  # The existing fork remote is authoritative; a redundant --fork-url is ignored.
  assert_contains "$out" "--fork-url ignored" "an ignored --fork-url is warned about"
  assert_contains "$out" "target: origin=$fork_url" "the target report matches the URL actually applied"
  [ "$(url "$w/home" origin)" = "$fork_url" ] || fail "origin is not the existing fork url ($(url "$w/home" origin) != $fork_url)"
  [ "$(url "$w/home" origin)" != "$bogus" ] || fail "origin was set to the ignored --fork-url"
  pass "to-fork promotes the existing fork remote and ignores --fork-url, report matches applied"
}

test_partial_target_layouts_are_not_idempotent_successes() {
  local w out rc
  w=$(new_home partial-fork-layout)
  git -C "$w/home" remote remove fork
  git -C "$w/home" remote rename origin upstream

  out=$(run to-fork "$w/home"); rc=$?
  [ "$rc" -eq 2 ] || fail "an upstream-only layout was accepted as fork-as-source"
  assert_contains "$out" "has no origin remote" \
    "upstream-only layout refusal did not name the missing origin"

  w=$(new_home partial-origin-layout)
  git -C "$w/home" remote remove origin

  out=$(run to-origin "$w/home"); rc=$?
  [ "$rc" -eq 2 ] || fail "a fork-only layout was accepted as original-as-origin"
  assert_contains "$out" "has no origin remote" \
    "fork-only layout refusal did not name the missing origin"
  pass "partial remote layouts fail closed instead of passing idempotence"
}

test_remote_configuration_is_remapped_reversibly() {
  local w out
  w=$(new_home config-roundtrip)
  mkdir -p "$w/home/config"
  printf 'fork\n' > "$w/home/config/update-remote"
  printf 'origin\n' > "$w/home/config/fork-feed-source"
  printf 'fork\n' > "$w/home/config/fork-feed-target"

  out=$(run to-fork "$w/home")
  assert_contains "$out" "update-remote: fork -> origin" \
    "dry run did not show the update remote remap"
  [ "$(cat "$w/home/config/update-remote")" = fork ] \
    || fail "dry run changed update-remote"

  out=$(run to-fork "$w/home" --apply)
  assert_contains "$out" "done:" "to-fork with configuration did not complete"
  [ "$(cat "$w/home/config/update-remote")" = origin ] \
    || fail "to-fork left update-remote pointing at the removed fork name"
  [ "$(cat "$w/home/config/fork-feed-source")" = upstream ] \
    || fail "to-fork did not preserve the feed source across the origin rename"
  [ "$(cat "$w/home/config/fork-feed-target")" = origin ] \
    || fail "to-fork did not preserve the feed target across the fork rename"

  run to-origin "$w/home" --apply >/dev/null
  [ "$(cat "$w/home/config/update-remote")" = fork ] \
    || fail "to-origin did not restore update-remote"
  [ "$(cat "$w/home/config/fork-feed-source")" = origin ] \
    || fail "to-origin did not restore the feed source"
  [ "$(cat "$w/home/config/fork-feed-target")" = fork ] \
    || fail "to-origin did not restore the feed target"
  pass "remote configuration follows names through a reversible round-trip"
}

test_missing_configured_remote_refuses_before_repointing() {
  local w out rc origin_before fork_before
  w=$(new_home missing-config-remote)
  mkdir -p "$w/home/config"
  printf 'missing\n' > "$w/home/config/update-remote"
  origin_before=$(url "$w/home" origin)
  fork_before=$(url "$w/home" fork)

  out=$(run to-fork "$w/home" --apply); rc=$?

  [ "$rc" -eq 2 ] || fail "repoint accepted configuration naming a missing remote"
  assert_contains "$out" "names missing remote 'missing'" \
    "incompatible configuration refusal did not name the missing remote"
  [ "$(url "$w/home" origin)" = "$origin_before" ] \
    || fail "repoint changed origin before rejecting incompatible configuration"
  [ "$(url "$w/home" fork)" = "$fork_before" ] \
    || fail "repoint changed fork before rejecting incompatible configuration"
  pass "incompatible remote configuration refuses before mutation"
}

test_status_reports_layout
test_dry_run_mutates_nothing
test_to_fork_and_roundtrip
test_idempotent_to_fork
test_unexpected_state_fails_closed
test_no_fork_remote_requires_url
test_fork_url_ignored_when_fork_remote_present
test_partial_target_layouts_are_not_idempotent_successes
test_remote_configuration_is_remapped_reversibly
test_missing_configured_remote_refuses_before_repointing

echo "# all fm-repoint-home tests passed"
