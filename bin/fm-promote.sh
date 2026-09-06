#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
# A scout records the base it was created from. Promotion to a PR-opening mode
# refuses that base when freshly fetched origin cannot reach it, preventing
# local-only history from riding into the pull request. Promotion also records
# the implementation base selected for the worker's reset. Missing evidence is
# reported, not hidden.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-delivery-lib.sh
. "$SCRIPT_DIR/fm-delivery-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

MODE=
YOLO=
MODE_SET=0
YOLO_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>" >&2; exit 1; }
[ "$MODE_SET" -eq 1 ] || {
  echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
  exit 1
}
[ "$YOLO_SET" -eq 1 ] || {
  echo "error: promotion requires --yolo <on|off>; it is this task's routine approval authority, not a project lookup" >&2
  exit 1
}
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  no-mistakes-prod-only)
    echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
    exit 1 ;;
  *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
esac
case "$YOLO" in
  on|off) ;;
  *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
esac

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
SPAWN_BASE=$(grep '^base=' "$META" | tail -1 | cut -d= -f2- || true)
IMPLEMENTATION_BASE=""
IMPLEMENTATION_BASE_UNVERIFIED=""
BASE_DEFAULT=""
BASE_ORIGIN_REV=""
BASE_LOCAL_REV=""
ORIGIN_REFRESH_ERROR=""
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  IMPLEMENTATION_BASE_UNVERIFIED="task $ID has no available recorded worktree"
else
  BASE_DEFAULT=$(default_branch "$WT" 2>/dev/null || true)
  if [ -z "$BASE_DEFAULT" ]; then
    IMPLEMENTATION_BASE_UNVERIFIED="the default branch for task $ID cannot be determined"
  else
    BASE_LOCAL_REV=$(git -C "$WT" rev-parse --verify --quiet "refs/heads/$BASE_DEFAULT^{commit}" 2>/dev/null || true)
    if git -C "$WT" remote get-url origin >/dev/null 2>&1; then
      if git -C "$WT" fetch --quiet origin "+refs/heads/$BASE_DEFAULT:refs/remotes/origin/$BASE_DEFAULT"; then
        BASE_ORIGIN_REV=$(git -C "$WT" rev-parse --verify --quiet "refs/remotes/origin/$BASE_DEFAULT^{commit}" 2>/dev/null || true)
        [ -n "$BASE_ORIGIN_REV" ] || ORIGIN_REFRESH_ERROR="freshly fetched origin/$BASE_DEFAULT does not resolve in $WT"
      else
        ORIGIN_REFRESH_ERROR="could not refresh origin/$BASE_DEFAULT for task $ID"
      fi
    elif fm_delivery_opens_pull_request "$MODE"; then
      ORIGIN_REFRESH_ERROR="task $ID has no origin remote"
    fi
  fi
fi

if fm_delivery_opens_pull_request "$MODE"; then
  if [ -n "$BASE_ORIGIN_REV" ]; then
    IMPLEMENTATION_BASE=$BASE_ORIGIN_REV
  elif [ -z "$IMPLEMENTATION_BASE_UNVERIFIED" ]; then
    IMPLEMENTATION_BASE_UNVERIFIED=${ORIGIN_REFRESH_ERROR:-"origin/${BASE_DEFAULT:-<default>} does not resolve in $WT"}
  fi
elif [ -z "$IMPLEMENTATION_BASE_UNVERIFIED" ]; then
  if [ -n "$ORIGIN_REFRESH_ERROR" ]; then
    IMPLEMENTATION_BASE_UNVERIFIED=$ORIGIN_REFRESH_ERROR
  elif [ -z "$BASE_ORIGIN_REV" ]; then
    if [ -n "$BASE_LOCAL_REV" ]; then
      IMPLEMENTATION_BASE=$BASE_LOCAL_REV
    else
      IMPLEMENTATION_BASE_UNVERIFIED="neither ${BASE_DEFAULT:-<default>} nor origin/${BASE_DEFAULT:-<default>} resolves in $WT"
    fi
  elif [ -z "$BASE_LOCAL_REV" ]; then
    IMPLEMENTATION_BASE=$BASE_ORIGIN_REV
  elif git -C "$WT" merge-base --is-ancestor "$BASE_LOCAL_REV" "$BASE_ORIGIN_REV" 2>/dev/null; then
    IMPLEMENTATION_BASE=$BASE_ORIGIN_REV
  else
    ANCESTOR_STATUS=$?
    if [ "$ANCESTOR_STATUS" -ne 1 ]; then
      IMPLEMENTATION_BASE_UNVERIFIED="could not compare $BASE_DEFAULT with origin/$BASE_DEFAULT for task $ID"
    elif git -C "$WT" merge-base --is-ancestor "$BASE_ORIGIN_REV" "$BASE_LOCAL_REV" 2>/dev/null; then
      IMPLEMENTATION_BASE=$BASE_LOCAL_REV
    else
      ANCESTOR_STATUS=$?
      if [ "$ANCESTOR_STATUS" -eq 1 ]; then
        IMPLEMENTATION_BASE_UNVERIFIED="$BASE_DEFAULT and origin/$BASE_DEFAULT have diverged for task $ID"
      else
        IMPLEMENTATION_BASE_UNVERIFIED="could not compare origin/$BASE_DEFAULT with $BASE_DEFAULT for task $ID"
      fi
    fi
  fi
fi

if fm_delivery_opens_pull_request "$MODE"; then
  BASE_UNVERIFIED=""
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    BASE_UNVERIFIED="task $ID has no available recorded worktree"
  else
    BASE_REV=""
    [ -z "$SPAWN_BASE" ] || BASE_REV=$(git -C "$WT" rev-parse --verify --quiet "$SPAWN_BASE^{commit}" 2>/dev/null || true)
    if [ -z "$SPAWN_BASE" ]; then
      BASE_UNVERIFIED="task $ID records no spawn base"
    elif [ -z "$BASE_REV" ]; then
      BASE_UNVERIFIED="the spawn base recorded for task $ID ($SPAWN_BASE) is not a commit in $WT"
    elif [ -n "$ORIGIN_REFRESH_ERROR" ]; then
      BASE_UNVERIFIED=$ORIGIN_REFRESH_ERROR
    elif [ -z "$BASE_ORIGIN_REV" ]; then
      BASE_UNVERIFIED="origin/${BASE_DEFAULT:-<default>} does not resolve in $WT"
    fi
  fi
  if [ -n "$BASE_UNVERIFIED" ]; then
    echo "note: $BASE_UNVERIFIED, and mode=$MODE opens a pull request against origin; promoting anyway, but confirm by hand that this task's base carries nothing origin has not seen" >&2
  else
    if ! BASE_UNPUSHED=$(git -C "$WT" rev-list --count "$BASE_ORIGIN_REV..$BASE_REV" 2>/dev/null); then
      BASE_UNVERIFIED="could not verify whether the spawn base recorded for task $ID carries commits origin/$BASE_DEFAULT has not seen"
    elif [ -z "$BASE_UNPUSHED" ] || [ -n "${BASE_UNPUSHED//[0-9]/}" ]; then
      BASE_UNVERIFIED="the spawn base recorded for task $ID produced an invalid reachability count '$BASE_UNPUSHED'"
    fi
    if [ -n "$BASE_UNVERIFIED" ]; then
      echo "note: $BASE_UNVERIFIED, and mode=$MODE opens a pull request against origin; promoting anyway, but confirm by hand that this task's base carries nothing origin has not seen" >&2
    elif [ "$BASE_UNPUSHED" -gt 0 ]; then
      if [ "$BASE_UNPUSHED" -eq 1 ]; then BASE_UNIT=commit; else BASE_UNIT=commits; fi
      echo "error: the base task $ID was spawned from carries $BASE_UNPUSHED $BASE_UNIT origin/$BASE_DEFAULT does not, and mode=$MODE opens a pull request against origin; refusing to promote rather than publish that unpushed local history inside the PR" >&2
      exit 1
    fi
  fi
fi

if ! fm_delivery_opens_pull_request "$MODE" && [ -z "$IMPLEMENTATION_BASE" ]; then
  echo "note: $IMPLEMENTATION_BASE_UNVERIFIED; promotion will record no implementation base, so review will refuse until that provenance is recorded" >&2
fi

TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' -e '^promoted_from_scout=' -e '^implementation_base=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "promoted_from_scout=1"
  [ -z "$IMPLEMENTATION_BASE" ] || echo "implementation_base=$IMPLEMENTATION_BASE"
} >> "$TMP"
mv "$TMP" "$META"
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

HOME_Q=$(printf '%q' "$FM_HOME")
echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
if [ -n "$IMPLEMENTATION_BASE" ]; then
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to recorded implementation base $IMPLEMENTATION_BASE; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
else
  echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; resolve and record implementation_base= before resetting to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"
fi
