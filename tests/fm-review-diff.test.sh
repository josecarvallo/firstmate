#!/usr/bin/env bash
# Tests for bin/fm-review-diff.sh: when a task has an open PR recorded in meta,
# the review diff must compare the authoritative base against a freshly fetched
# PR head, not a stale local branch or a stale recorded pr_head= left behind
# after no-mistakes fix rounds push to the PR.
#
# Matrix:
#   (a) pr= + reachable pr_head=, no remote pull ref -> offline fallback to recorded SHA
#   (b) pr= without pr_head= -> fetch refs/pull/<n>/head and diff that
#   (c) pr= absent -> unchanged worktree-branch diff
#   (d) pr= present but PR head unreachable -> fallback to local branch + warning
#   (e) pr= + STALE recorded pr_head= + newer remote pull head -> must use fetched head
#       (this is the class that bit reviewers holding merges over "missing" fixes)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-diff-tests)

make_case() {
  local name=$1 case_dir
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir/state"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  printf 'base\n' > "$case_dir/_seed/feature.txt"
  git -C "$case_dir/_seed" add feature.txt
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t commit -qm "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b fm/task-x1 "$case_dir/wt" main

  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task_meta() {
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=fm-task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "$@"
}

stale_and_pr_commits() {
  local case_dir=$1
  printf 'stale-local\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "stale local branch"

  git -C "$case_dir/wt" checkout -q -b pr-head-tmp
  printf 'pr-fixed\n' > "$case_dir/wt/feature.txt"
  git -C "$case_dir/wt" add feature.txt
  git -C "$case_dir/wt" commit -qm "pipeline fix on PR"
  PR_SHA=$(git -C "$case_dir/wt" rev-parse HEAD)

  git -C "$case_dir/wt" checkout -q fm/task-x1
}

run_review_diff() {
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$@"
}

test_pr_meta_uses_pr_head_not_stale_local() {
  local case_dir out
  case_dir=$(make_case pr-head-sha)
  stale_and_pr_commits "$case_dir"
  # No remote pull ref: fetch fails, recorded pr_head is the offline fallback.
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$PR_SHA"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-head-sha: diff should show the PR head content"
  assert_not_contains "$out" 'stale-local' "pr-head-sha: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-head-sha: should not warn when recorded pr_head is reachable offline"
  pass "fm-review-diff falls back to recorded pr_head when pull head cannot be fetched"
}

test_stale_recorded_pr_head_loses_to_fetched_pull_head() {
  local case_dir out stale_sha
  case_dir=$(make_case stale-recorded)
  stale_and_pr_commits "$case_dir"
  stale_sha=$(git -C "$case_dir/wt" rev-parse fm/task-x1)
  # Remote PR head is newer (pipeline fix); meta still points at the older local tip.
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=$stale_sha"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' \
    "stale-recorded: diff must show the fetched PR head, not the recorded stale SHA"
  assert_not_contains "$out" 'stale-local' \
    "stale-recorded: diff must not use the stale local/recorded content"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "stale-recorded: fetch of refs/pull/<n>/head should succeed"
  # Pre-fix behavior preferred reachable recorded pr_head= and would show stale-local.
  [ "$stale_sha" != "$PR_SHA" ] || fail "stale-recorded: fixture did not diverge recorded vs PR head"
  pass "fm-review-diff prefers freshly fetched PR head over a stale recorded pr_head="
}

test_pr_meta_fetches_pull_head_without_recorded_sha() {
  local case_dir out
  case_dir=$(make_case pr-fetch)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" push -q origin "pr-head-tmp:refs/pull/9/head"
  write_task_meta "$case_dir" "pr=https://github.com/example/repo/pull/9"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+pr-fixed' "pr-fetch: diff should use fetched PR head"
  assert_not_contains "$out" 'stale-local' "pr-fetch: diff must not use the stale local branch"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "pr-fetch: should not warn when fetch succeeds"
  pass "fm-review-diff fetches refs/pull/<n>/head when pr_head= is absent"
}

test_no_pr_meta_uses_local_branch() {
  local case_dir out
  case_dir=$(make_case no-pr-meta)
  stale_and_pr_commits "$case_dir"
  write_task_meta "$case_dir"

  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")

  assert_contains "$out" '+stale-local' "no-pr-meta: diff should still use the local branch"
  assert_not_contains "$out" '+pr-fixed' "no-pr-meta: diff must not jump to the unpushed PR commit"
  assert_not_contains "$(cat "$case_dir/stderr")" 'warning: PR head unavailable' \
    "no-pr-meta: no warning without pr= in meta"
  pass "fm-review-diff without pr= keeps the worktree-branch diff"
}

test_unreachable_pr_head_falls_back_with_warning() {
  local case_dir out err
  case_dir=$(make_case fetch-fallback)
  stale_and_pr_commits "$case_dir"
  git -C "$case_dir/wt" remote remove origin
  write_task_meta "$case_dir" \
    "pr=https://github.com/example/repo/pull/9" \
    "pr_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 2> "$case_dir/stderr")
  set -e
  err=$(cat "$case_dir/stderr")

  assert_contains "$err" 'warning: PR head unavailable; diff may lag the open PR' \
    "fetch-fallback: must warn when PR head cannot be resolved"
  assert_contains "$out" '+stale-local' "fetch-fallback: should fall back to the local branch diff"
  assert_not_contains "$out" '+pr-fixed' "fetch-fallback: must not invent a PR head diff offline"
  pass "fm-review-diff falls back to local branch with a warning when PR head is unreachable"
}

test_delivery_mode_selects_the_same_base_as_spawn() {
  local case_dir out
  case_dir=$(make_case local-base)
  printf 'local landing\n' > "$case_dir/project/local.txt"
  git -C "$case_dir/project" add local.txt
  git -C "$case_dir/project" commit -qm "local landing"
  printf 'task change\n' > "$case_dir/wt/task.txt"
  git -C "$case_dir/wt" add task.txt
  git -C "$case_dir/wt" commit -qm "task change"

  write_task_meta "$case_dir" "mode=local-only"
  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")
  assert_contains "$out" "diff base: main" \
    "local-only review did not use the primary checkout's newer base"

  write_task_meta "$case_dir" "mode=direct-PR"
  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")
  assert_contains "$out" "diff base: origin/main" \
    "PR review did not stay anchored on the forge tip"
  pass "fm-review-diff reads the shared delivery rule used by spawn and promotion"
}

test_review_refreshes_origin_default_branch_ownership() {
  local case_dir publisher out
  case_dir=$(make_case refreshed-default)
  publisher="$case_dir/publisher"
  git clone -q "$case_dir/origin.git" "$publisher"
  git -C "$publisher" checkout -q -b stable
  git -C "$publisher" push -q origin stable
  git -C "$case_dir/project" fetch -q origin '+refs/heads/stable:refs/remotes/origin/stable'
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
  printf 'stable base\n' > "$publisher/stable.txt"
  git -C "$publisher" add stable.txt
  git -C "$publisher" commit -qm "stable base"
  git -C "$publisher" push -q origin stable
  git --git-dir="$case_dir/origin.git" symbolic-ref HEAD refs/heads/stable
  [ "$(git -C "$case_dir/wt" rev-parse origin/stable)" != "$(git -C "$publisher" rev-parse HEAD)" ] \
    || fail "the restrictive-refspec review fixture did not leave origin/stable stale"
  printf 'task change\n' > "$case_dir/wt/task.txt"
  git -C "$case_dir/wt" add task.txt
  git -C "$case_dir/wt" commit -qm "task change"
  write_task_meta "$case_dir" "mode=direct-PR"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" "diff base: origin/stable" \
    "review used stale origin/main instead of origin/stable"
  assert_contains "$out" "task.txt" "review omitted the task change above the refreshed base"
  [ "$(git -C "$case_dir/wt" symbolic-ref --short refs/remotes/origin/HEAD)" = origin/stable ] \
    || fail "review did not refresh origin's default-branch ownership"
  pass "fm-review-diff refreshes origin default-branch ownership before base selection"
}

test_non_pr_review_uses_the_recorded_spawn_base_after_candidate_divergence() {
  local case_dir publisher base out
  case_dir=$(make_case recorded-base)
  publisher="$case_dir/publisher"
  git clone -q "$case_dir/origin.git" "$publisher"
  printf 'origin-only\n' > "$publisher/origin-only.txt"
  git -C "$publisher" add origin-only.txt
  git -C "$publisher" commit -qm "origin advances"
  git -C "$publisher" push -q origin main

  git -C "$case_dir/wt" fetch -q origin
  base=$(git -C "$case_dir/wt" rev-parse origin/main)
  git -C "$case_dir/wt" reset -q --hard "$base"
  printf 'task-only\n' > "$case_dir/wt/task-only.txt"
  git -C "$case_dir/wt" add task-only.txt
  git -C "$case_dir/wt" commit -qm "task change"

  printf 'local-only\n' > "$case_dir/project/local-only.txt"
  git -C "$case_dir/project" add local-only.txt
  git -C "$case_dir/project" commit -qm "local main diverges"
  write_task_meta "$case_dir" "mode=local-only" "base=$base"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" "diff base: $base" \
    "non-PR review did not stay anchored to its recorded spawn base"
  assert_contains "$out" "task-only.txt" \
    "non-PR review omitted the task change above its recorded base"
  assert_not_contains "$out" "origin-only.txt" \
    "non-PR review included an unrelated change already present at its recorded base"
  pass "fm-review-diff anchors non-PR work to the recorded spawn base"
}

test_promoted_non_pr_review_uses_the_implementation_base() {
  local case_dir scout_base implementation_base out
  case_dir=$(make_case promoted-base)
  scout_base=$(git -C "$case_dir/project" rev-parse main)
  printf 'local landing\n' > "$case_dir/project/local-only.txt"
  git -C "$case_dir/project" add local-only.txt
  git -C "$case_dir/project" commit -qm "local landing"
  implementation_base=$(git -C "$case_dir/project" rev-parse main)
  git -C "$case_dir/wt" reset -q --hard "$implementation_base"
  printf 'task-only\n' > "$case_dir/wt/task-only.txt"
  git -C "$case_dir/wt" add task-only.txt
  git -C "$case_dir/wt" commit -qm "promoted task change"
  write_task_meta "$case_dir" \
    "kind=ship" \
    "mode=local-only" \
    "promoted_from_scout=1" \
    "base=$scout_base" \
    "implementation_base=$implementation_base"

  out=$(run_review_diff "$case_dir" task-x1 --stat 2> "$case_dir/stderr")

  assert_contains "$out" "diff base: $implementation_base" \
    "promoted review did not use the recorded implementation base"
  assert_contains "$out" "task-only.txt" \
    "promoted review omitted the implementation change"
  assert_not_contains "$out" "local-only.txt" \
    "promoted review included the unrelated landing between scout and implementation"
  pass "fm-review-diff uses promoted implementation provenance"
}

test_promoted_non_pr_review_refuses_missing_implementation_provenance() {
  local case_dir out status
  case_dir=$(make_case promoted-missing-base)
  write_task_meta "$case_dir" \
    "kind=ship" \
    "mode=local-only" \
    "promoted_from_scout=1" \
    "base=$(git -C "$case_dir/wt" rev-parse HEAD)"

  set +e
  out=$(run_review_diff "$case_dir" task-x1 --stat 2>&1)
  status=$?
  set -e

  [ "$status" -ne 0 ] || fail "promoted review trusted a stale scout base without implementation provenance"
  assert_contains "$out" "records no implementation_base=" \
    "promoted review refusal did not name the missing provenance"
  pass "fm-review-diff refuses promoted work without implementation provenance"
}

test_pr_meta_uses_pr_head_not_stale_local
test_pr_meta_fetches_pull_head_without_recorded_sha
test_stale_recorded_pr_head_loses_to_fetched_pull_head
test_no_pr_meta_uses_local_branch
test_unreachable_pr_head_falls_back_with_warning
test_delivery_mode_selects_the_same_base_as_spawn
test_review_refreshes_origin_default_branch_ownership
test_non_pr_review_uses_the_recorded_spawn_base_after_candidate_divergence
test_promoted_non_pr_review_uses_the_implementation_base
test_promoted_non_pr_review_refuses_missing_implementation_provenance
