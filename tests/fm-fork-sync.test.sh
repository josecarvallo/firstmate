#!/usr/bin/env bash
# Tests for bin/fm-fork-sync.sh: feed the captain's fork from the original.
#
# The guarantees under test mirror the fork-as-source model and prime directive #3:
#   - When the fork branch is a clean fast-forward of the original, --apply
#     advances the fork branch to the original's tip; report-only never pushes.
#   - FAST-FORWARD ONLY on the fork branch, NEVER forced: a fork that carries its
#     own commits is never fast-forwarded; instead --apply publishes an
#     integration branch and the fork branch is left exactly where it was.
#   - A fork already ahead of the original is reported as nothing-to-feed.
#   - Missing remote / same remote / fetch failure fail closed (exit 2), distinct
#     from an ordinary "nothing to do" (exit 0).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-fork-sync.sh"
fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-fork-sync-tests)

# Build a world: an `original.git` (upstream) and `fork.git` (target) bare repo
# both seeded at one shared commit A, plus a `work` clone whose remotes are
# upstream->original and origin->fork (the standard fork-as-source layout).
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w"
  git init -q --bare "$w/original.git"
  git -C "$w/original.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/original.git" "$w/seed" 2>/dev/null
  printf 'A\n' > "$w/seed/f"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm A
  git -C "$w/seed" push -q origin main
  # fork starts identical to the original at A.
  git clone -q --bare "$w/original.git" "$w/fork.git"
  git clone -q "$w/original.git" "$w/work"
  git -C "$w/work" remote rename origin upstream
  git -C "$w/work" remote add origin "$w/fork.git"
  git -C "$w/work" remote set-head origin main >/dev/null 2>&1 || true
  printf '%s\n' "$w"
}

# Add a commit to a bare repo (which=original|fork) and echo nothing. Uses a
# throwaway clone so the bare repo advances by a real push.
advance() {
  local w=$1 which=$2 msg=$3 c
  c="$TMP_ROOT/tmp-$which-$RANDOM"
  git clone -q "$w/$which.git" "$c" 2>/dev/null
  printf '%s\n' "$msg" >> "$c/f"
  git -C "$c" add -A
  git -C "$c" commit -qm "$msg"
  git -C "$c" push -q origin main
  rm -rf "$c"
}

run_sync() { local w=$1; shift; FM_ROOT_OVERRIDE="$w/work" "$SYNC" "$@" 2>&1; }
fork_main() { git -C "$1/fork.git" rev-parse main; }
orig_main() { git -C "$1/original.git" rev-parse main; }

install_git_failure() {
  local w=$1 fakebin
  fakebin=$(fm_fakebin "$w/git-failure")
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
real=${REAL_GIT_FOR_TEST:?}
for arg in "$@"; do
  if [ "$arg" = "${FAIL_GIT_SUBCOMMAND:-}" ]; then
    exit 70
  fi
done
exec "$real" "$@"
SH
  chmod +x "$fakebin/git"
  printf '%s\n' "$fakebin"
}

# --- clean fast-forward: report-only never pushes, --apply advances the fork
test_clean_ff() {
  local w out before
  w=$(new_world ff)
  advance "$w" original B          # original ahead; fork still at A
  before=$(fork_main "$w")

  out=$(run_sync "$w")             # report only
  assert_contains "$out" "fast-forward available" "clean ff reported"
  [ "$(fork_main "$w")" = "$before" ] || fail "report-only pushed to the fork"

  out=$(run_sync "$w" --apply)
  assert_contains "$out" "updated: fast-forwarded" "ff applied"
  [ "$(fork_main "$w")" = "$(orig_main "$w")" ] || fail "fork did not advance to the original's tip"
  pass "clean fast-forward: report-only is safe, --apply feeds the fork"
}

# --- diverged: fork's own commit is never discarded, an integration branch is
# published instead, and nothing is force-pushed
test_diverged_never_discards() {
  local w out fork_before
  w=$(new_world div)
  advance "$w" original B          # original: A->B
  advance "$w" fork X              # fork: A->X (own work)
  fork_before=$(fork_main "$w")

  out=$(run_sync "$w")
  assert_contains "$out" "diverged" "divergence reported"

  out=$(run_sync "$w" --apply)
  assert_contains "$out" "integration branch: pushed" "integration branch published"
  [ "$(fork_main "$w")" = "$fork_before" ] || fail "fork's own commit was moved (unlanded work at risk)"
  # An integration branch now exists on the fork at the original's tip.
  git -C "$w/fork.git" for-each-ref --format='%(refname)' 'refs/heads/integrate-upstream-*' \
    | grep -q . || fail "no integration branch was created"
  pass "diverged: fork's own work preserved, integration branch published, no force"
}

# --- fork already ahead of the original: nothing to feed
test_fork_ahead_nothing_to_feed() {
  local w out before
  w=$(new_world ahead)
  advance "$w" fork X              # fork ahead by its own commit; original at A
  before=$(fork_main "$w")

  out=$(run_sync "$w" --apply)
  assert_contains "$out" "nothing new to feed" "fork-ahead reported as nothing to feed"
  [ "$(fork_main "$w")" = "$before" ] || fail "fork moved when there was nothing to feed"
  pass "fork ahead of the original is a no-op"
}

# --- already current: identical tips
test_already_current() {
  local w out
  w=$(new_world cur)
  advance "$w" original B
  # bring the fork to B as well (a clean ff), then re-run.
  run_sync "$w" --apply >/dev/null
  out=$(run_sync "$w")
  assert_contains "$out" "up to date: " "identical tips reported up to date"
  pass "already-current fork is a no-op"
}

# --- fail closed on a missing remote
test_missing_remote_fails_closed() {
  local w out rc
  w=$(new_world miss)
  git -C "$w/work" remote remove upstream
  out=$(run_sync "$w"); rc=$?
  [ "$rc" -eq 2 ] || fail "missing remote did not exit 2 (got $rc)"
  assert_contains "$out" "no upstream remote" "missing remote named"
  pass "a missing feed remote fails closed"
}

test_config_remote_with_internal_whitespace_is_rejected() {
  local w out rc
  w=$(new_world unsafe-config)
  mkdir -p "$w/work/config"
  printf 'up stream\n' > "$w/work/config/fork-feed-source"

  out=$(run_sync "$w"); rc=$?

  [ "$rc" -eq 2 ] || fail "unsafe configured remote did not exit 2 (got $rc)"
  assert_contains "$out" "unsafe remote name: 'up stream'" \
    "internal whitespace was collapsed into a different valid remote"
  pass "a configured remote with internal whitespace is rejected"
}

test_relationship_traversal_failure_refuses_without_publishing() {
  local w out rc fakebin refs_before
  w=$(new_world relationship-failure)
  advance "$w" original B
  advance "$w" fork X
  refs_before=$(git -C "$w/fork.git" for-each-ref --format='%(refname) %(objectname)' refs/heads)
  fakebin=$(install_git_failure "$w")

  out=$(REAL_GIT_FOR_TEST="$(command -v git)" FAIL_GIT_SUBCOMMAND=merge-base \
    PATH="$fakebin:$PATH" run_sync "$w" --apply); rc=$?

  [ "$rc" -eq 2 ] || fail "relationship traversal failure did not exit 2 (got $rc)"
  assert_contains "$out" "could not determine whether" \
    "relationship traversal failure was misclassified as divergence"
  [ "$(git -C "$w/fork.git" for-each-ref --format='%(refname) %(objectname)' refs/heads)" = "$refs_before" ] \
    || fail "relationship traversal failure published or moved a fork ref"
  pass "relationship traversal failure refuses without publishing"
}

test_count_traversal_failure_refuses_without_fast_forwarding() {
  local w out rc fakebin fork_before
  w=$(new_world count-failure)
  advance "$w" original B
  fork_before=$(fork_main "$w")
  fakebin=$(install_git_failure "$w")

  out=$(REAL_GIT_FOR_TEST="$(command -v git)" FAIL_GIT_SUBCOMMAND=rev-list \
    PATH="$fakebin:$PATH" run_sync "$w" --apply); rc=$?

  [ "$rc" -eq 2 ] || fail "count traversal failure did not exit 2 (got $rc)"
  assert_contains "$out" "could not count commit range" \
    "count traversal failure was converted to a fabricated count"
  [ "$(fork_main "$w")" = "$fork_before" ] \
    || fail "count traversal failure fast-forwarded the fork"
  pass "count traversal failure refuses without moving the fork"
}

test_clean_ff
test_diverged_never_discards
test_fork_ahead_nothing_to_feed
test_already_current
test_missing_remote_fails_closed
test_config_remote_with_internal_whitespace_is_rejected
test_relationship_traversal_failure_refuses_without_publishing
test_count_traversal_failure_refuses_without_fast_forwarding

echo "# all fm-fork-sync tests passed"
