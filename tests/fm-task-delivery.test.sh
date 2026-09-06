#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status source origin remote_abs real_git fetch_log n
  local before_head before_count before_worktrees before_branches
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  # A real shallow clone plus a fetch-recording Git wrapper proves the delivery
  # refusal wins before either automatic history repair or lane preparation.
  source="$TMP_ROOT/agreement/source"
  origin="$TMP_ROOT/agreement/origin.git"
  git init --quiet -b main "$source"
  for n in 1 2 3; do
    printf 'history %s\n' "$n" > "$source/README.md"
    git -C "$source" add README.md
    git -C "$source" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
      commit -qm "history-$n"
  done
  git clone --quiet --bare "$source" "$origin"
  remote_abs=$(cd "$origin" && pwd -P)
  rmdir "$proj"
  # This private, disposable fixture may use --depth; it shares neither the project clone nor any lane object store.
  git clone --quiet --depth 1 "file://$remote_abs" "$proj"
  [ "$(git -C "$proj" rev-parse --is-shallow-repository)" = true ] \
    || fail "delivery mismatch fixture is not shallow"
  before_head=$(git -C "$proj" rev-parse HEAD)
  before_count=$(git -C "$proj" rev-list --count HEAD)
  before_worktrees=$(git -C "$proj" worktree list --porcelain)
  before_branches=$(git -C "$proj" for-each-ref --format='%(refname)' refs/heads)

  real_git=$(command -v git)
  fetch_log="$TMP_ROOT/agreement/fetch.log"
  {
    printf '#!/bin/sh\n'
    printf 'for arg in "$@"; do\n'
    printf "  [ \"\$arg\" = fetch ] && printf \"fetch\\\\n\" >> \"%s\"\n" "$fetch_log"
    printf 'done\n'
    printf 'exec "%s" "$@"\n' "$real_git"
  } > "$fakebin/git"
  chmod +x "$fakebin/git"

  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"
  assert_absent "$fetch_log" "mismatched spawn fetched the shallow project before refusing"
  [ "$(git -C "$proj" rev-parse --is-shallow-repository)" = true ] \
    || fail "mismatched spawn repaired the shallow project before refusing"
  [ "$(git -C "$proj" rev-parse HEAD)" = "$before_head" ] \
    || fail "mismatched spawn moved the project HEAD before refusing"
  [ "$(git -C "$proj" rev-list --count HEAD)" = "$before_count" ] \
    || fail "mismatched spawn changed the visible project history before refusing"
  [ "$(git -C "$proj" worktree list --porcelain)" = "$before_worktrees" ] \
    || fail "mismatched spawn changed the project worktree inventory before refusing"
  [ "$(git -C "$proj" for-each-ref --format='%(refname)' refs/heads)" = "$before_branches" ] \
    || fail "mismatched spawn changed the project branches before refusing"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing approval posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided approval posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

test_promote_refuses_a_pr_contract_on_an_unpublished_base() {
  local root home project origin wt base out status
  root="$TMP_ROOT/promote-unpublished"
  home="$root/home"
  project="$root/project"
  origin="$root/origin.git"
  wt="$root/wt"
  mkdir -p "$home/state"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  printf 'local only\n' > "$project/local.txt"
  git -C "$project" add local.txt
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-only
  base=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$wt" "$base"
  printf 'window=fm-promote-u1\nkind=scout\nworktree=%s\nbase=%s\n' "$wt" "$base" \
    > "$home/state/promote-u1.meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-u1 --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion accepted a base origin has not seen"
  assert_contains "$out" "carries 1 commit origin/main does not" \
    "promotion refusal did not report the unpublished commit count"
  assert_grep 'kind=scout' "$home/state/promote-u1.meta" \
    "refused promotion still changed the task kind"
  pass "fm-promote: a PR contract cannot silently inherit a locally landed base"
}

test_promote_reports_an_unreadable_base_reachability_check() {
  local root home project origin wt base out status fakebin real_git
  root="$TMP_ROOT/promote-unreadable"
  home="$root/home"
  project="$root/project"
  origin="$root/origin.git"
  wt="$root/wt"
  fakebin=$(fm_fakebin "$root/fake")
  mkdir -p "$home/state"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  base=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$wt" "$base"
  printf 'window=fm-promote-u2\nkind=scout\nworktree=%s\nbase=%s\n' "$wt" "$base" \
    > "$home/state/promote-u2.meta"

  real_git=$(command -v git)
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
set -u
real=${REAL_GIT_FOR_TEST:?}
dir=
prev=
is_rev_list=0
range=
for arg in "$@"; do
  [ "$prev" = -C ] && dir=$arg
  [ "$arg" = rev-list ] && is_rev_list=1
  case "$arg" in *..*) range=$arg ;; esac
  prev=$arg
done
if [ "$is_rev_list" -eq 1 ] && [ "$dir" = "${FAIL_REV_LIST_DIR:-}" ] && [ -n "$range" ]; then
  exit 70
fi
exec "$real" "$@"
SH
  chmod +x "$fakebin/git"

  out=$(REAL_GIT_FOR_TEST="$real_git" FAIL_REV_LIST_DIR="$wt" PATH="$fakebin:$PATH" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-u2 --mode direct-PR --yolo off 2>&1)
  status=$?

  expect_code 0 "$status" "an unverified promotion should follow the existing loud manual-confirmation path"
  assert_contains "$out" "could not verify whether the spawn base recorded for task promote-u2" \
    "promotion silently treated a failed reachability traversal as zero commits"
  assert_contains "$out" "confirm by hand" \
    "promotion did not route traversal failure through manual confirmation"
  assert_grep 'kind=ship' "$home/state/promote-u2.meta" \
    "the existing unverified promotion path did not complete"
  pass "fm-promote reports failed base reachability traversal before promotion"
}

test_promote_refreshes_origin_before_checking_the_scout_base() {
  local root home project origin wt base previous out status
  root="$TMP_ROOT/promote-fresh-origin"
  home="$root/home"
  project="$root/project"
  origin="$root/origin.git"
  wt="$root/wt"
  mkdir -p "$home/state"
  git init --quiet -b main "$project"
  printf 'A\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm A
  previous=$(git -C "$project" rev-parse HEAD)
  printf 'B\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm B
  base=$(git -C "$project" rev-parse HEAD)
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" worktree add --quiet --detach "$wt" "$base"
  printf 'window=fm-promote-u3\nkind=scout\nworktree=%s\nbase=%s\n' "$wt" "$base" \
    > "$home/state/promote-u3.meta"
  git --git-dir="$origin" update-ref refs/heads/main "$previous"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-u3 --mode direct-PR --yolo off 2>&1)
  status=$?

  [ "$status" -ne 0 ] || fail "promotion trusted a stale origin/main after the remote was rewritten"
  assert_contains "$out" "carries 1 commit origin/main does not" \
    "promotion did not compare the scout base with freshly fetched origin/main"
  [ "$(git -C "$wt" rev-parse origin/main)" = "$previous" ] \
    || fail "promotion did not refresh the exact origin/main tracking ref"
  assert_grep 'kind=scout' "$home/state/promote-u3.meta" \
    "promotion changed task kind after the fresh base check refused"
  pass "fm-promote checks scout reachability against freshly fetched origin"
}

test_promote_reports_origin_refresh_failure_instead_of_using_cache() {
  local root home project origin wt base out status
  root="$TMP_ROOT/promote-origin-offline"
  home="$root/home"
  project="$root/project"
  origin="$root/origin.git"
  wt="$root/wt"
  mkdir -p "$home/state"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  base=$(git -C "$project" rev-parse HEAD)
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" worktree add --quiet --detach "$wt" "$base"
  printf 'window=fm-promote-u5\nkind=scout\nworktree=%s\nbase=%s\n' "$wt" "$base" \
    > "$home/state/promote-u5.meta"
  git -C "$wt" remote set-url origin "file://$root/missing.git"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-u5 --mode direct-PR --yolo off 2>&1)
  status=$?

  expect_code 0 "$status" "origin refresh failure should follow the existing unverified promotion path"
  assert_contains "$out" "could not refresh origin/main for task promote-u5" \
    "promotion silently trusted cached origin/main after refresh failed"
  assert_contains "$out" "confirm by hand" \
    "origin refresh failure did not require manual base confirmation"
  assert_grep 'kind=ship' "$home/state/promote-u5.meta" \
    "the existing unverified promotion path did not complete after refresh failure"
  pass "fm-promote reports origin refresh failure instead of trusting cache"
}

test_promote_refreshes_origin_default_branch_ownership() {
  local root home project origin publisher wt base stable out status
  root="$TMP_ROOT/promote-origin-default"
  home="$root/home"
  project="$root/project"
  origin="$root/origin.git"
  publisher="$root/publisher"
  wt="$root/wt"
  mkdir -p "$home/state"
  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  base=$(git -C "$project" rev-parse HEAD)
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  git -C "$project" remote set-head origin main
  git clone --quiet "$origin" "$publisher"
  git -C "$publisher" checkout -q -b stable
  git -C "$publisher" push -q origin stable
  git -C "$project" fetch -q origin '+refs/heads/stable:refs/remotes/origin/stable'
  git -C "$project" config --unset-all remote.origin.fetch
  git -C "$project" config --add remote.origin.fetch '+refs/heads/main:refs/remotes/origin/main'
  printf 'stable\n' > "$publisher/stable.txt"
  git -C "$publisher" add stable.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm stable
  git -C "$publisher" push -q origin stable
  stable=$(git -C "$publisher" rev-parse HEAD)
  git --git-dir="$origin" symbolic-ref HEAD refs/heads/stable
  git -C "$project" worktree add --quiet --detach "$wt" "$base"
  [ "$(git -C "$wt" rev-parse origin/stable)" != "$stable" ] \
    || fail "the restrictive-refspec promotion fixture did not leave origin/stable stale"
  printf 'window=fm-promote-default\nkind=scout\nworktree=%s\nbase=%s\n' "$wt" "$base" \
    > "$home/state/promote-default.meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-default --mode direct-PR --yolo off 2>&1)
  status=$?

  expect_code 0 "$status" "promotion should follow origin's refreshed stable default"
  assert_grep "implementation_base=$stable" "$home/state/promote-default.meta" \
    "promotion recorded stale origin/main instead of origin/stable"
  [ "$(git -C "$wt" symbolic-ref --short refs/remotes/origin/HEAD)" = origin/stable ] \
    || fail "promotion did not refresh origin's default-branch ownership"
  assert_contains "$out" "reset to recorded implementation base $stable" \
    "promotion instructions did not use the refreshed origin default"
  pass "fm-promote refreshes origin default-branch ownership before base selection"
}

test_promote_records_the_local_implementation_base() {
  local root home project origin wt scout_base implementation_base out status
  root="$TMP_ROOT/promote-implementation-base"
  home="$root/home"
  project="$root/project"
  origin="$root/origin.git"
  wt="$root/wt"
  mkdir -p "$home/state"
  git init --quiet -b main "$project"
  printf 'A\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm A
  scout_base=$(git -C "$project" rev-parse HEAD)
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  printf 'local landing\n' > "$project/local.txt"
  git -C "$project" add local.txt
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm local-landing
  implementation_base=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$wt" "$scout_base"
  printf 'window=fm-promote-u4\nkind=scout\nworktree=%s\nbase=%s\n' "$wt" "$scout_base" \
    > "$home/state/promote-u4.meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-u4 --mode local-only --yolo off 2>&1)
  status=$?

  expect_code 0 "$status" "local-only promotion should resolve the newer local default base"
  assert_grep 'promoted_from_scout=1' "$home/state/promote-u4.meta" \
    "promotion did not mark the task's scout provenance"
  assert_grep "implementation_base=$implementation_base" "$home/state/promote-u4.meta" \
    "promotion did not record the effective local implementation base"
  assert_contains "$out" "reset to recorded implementation base $implementation_base" \
    "promotion instructions did not pin the worker reset to recorded provenance"
  pass "fm-promote records the implementation base selected for local work"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_refuses_a_pr_contract_on_an_unpublished_base
test_promote_reports_an_unreadable_base_reachability_check
test_promote_refreshes_origin_before_checking_the_scout_base
test_promote_reports_origin_refresh_failure_instead_of_using_cache
test_promote_refreshes_origin_default_branch_ownership
test_promote_records_the_local_implementation_base
test_project_mode_maps_the_conditional_policy
echo "# all fm-task-delivery tests passed"
