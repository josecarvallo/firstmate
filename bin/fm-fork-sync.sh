#!/usr/bin/env bash
# fm-fork-sync.sh - feed the captain's fork from the original, on demand.
#
# The fleet runs from the captain's fork (origin) and treats the original it was
# forked from (upstream) as a periodic feed of improvements. This script brings
# the original's landed work into the fork WITHOUT ever discarding the fork's own
# commits:
#   - when the fork's branch is a clean fast-forward of the original's, it
#     advances the fork's branch to the original's tip (only with --apply);
#   - when the fork carries its own commits the original does not have, it does
#     NOT fast-forward. With --apply it publishes an integration branch at the
#     original's tip so a reviewed merge can bring the original's changes in; the
#     fork's own branch is never moved and nothing is ever force-pushed.
#
# It is FAST-FORWARD ONLY on the fork's branch and NEVER forces, exactly like
# fm-update.sh / fm-fleet-sync.sh. It is report-only by default; --apply is what
# performs any push. It touches only git remotes of the firstmate repo, never
# anything under projects/.
#
# Remotes (standard fork-as-source convention):
#   from = the ORIGINAL / feed   (default: config/fork-feed-source, then upstream)
#   to   = the FORK / source-of-truth (default: config/fork-feed-target, then origin)
#
# Usage:
#   fm-fork-sync.sh [--from <remote>] [--to <remote>] [--branch <name>] [--apply]
#   fm-fork-sync.sh --help
#
# Exit status: 0 on a clean report or apply; 2 on a configuration/precondition
# error (missing remote, fetch failure, missing branch) so a caller can tell a
# real blocker from "nothing to do".
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-fork-sync.sh [--from <remote>] [--to <remote>] [--branch <name>] [--apply]
  Feed the fork (--to, default origin) from the original (--from, default upstream).
  Report-only by default; --apply performs a non-forced fast-forward of the fork's
  branch, or publishes an integration branch when the fork carries its own commits.
  Never forces and never discards the fork's own work.
EOF
}

# --- config-defaulted remote/branch resolution -----------------------------

config_first_line() {
  local name=$1 val=''
  if [ -f "$CONFIG_DIR/$name" ]; then
    val=$(sed -n '1p' "$CONFIG_DIR/$name" 2>/dev/null)
  fi
  printf '%s' "$val"
}

FROM=""
TO=""
BRANCH=""
APPLY=no

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM=${2:-}; shift 2 ;;
    --to) TO=${2:-}; shift 2 ;;
    --branch) BRANCH=${2:-}; shift 2 ;;
    --apply) APPLY=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "fm-fork-sync: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[ -n "$FROM" ] || FROM=$(config_first_line fork-feed-source)
[ -n "$FROM" ] || FROM=upstream
[ -n "$TO" ] || TO=$(config_first_line fork-feed-target)
[ -n "$TO" ] || TO=origin

# Reject anything that is not a safe remote-name token before it reaches git.
for r in "$FROM" "$TO"; do
  case "$r" in
    *[!A-Za-z0-9._-]*|'') echo "fm-fork-sync: unsafe remote name: '$r'" >&2; exit 2 ;;
  esac
done
if [ "$FROM" = "$TO" ]; then
  echo "fm-fork-sync: --from and --to are the same remote ('$FROM'); nothing to feed" >&2
  exit 2
fi

git_root() { git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
if ! git_root; then
  echo "fm-fork-sync: $FM_ROOT is not a git repository" >&2
  exit 2
fi

for r in "$FROM" "$TO"; do
  if ! git -C "$FM_ROOT" remote get-url "$r" >/dev/null 2>&1; then
    echo "fm-fork-sync: no $r remote (expected the ${r} remote on $FM_ROOT)" >&2
    exit 2
  fi
done

# --- fetch both sides (a fetch failure is a real blocker) ------------------

for r in "$FROM" "$TO"; do
  if ! git -C "$FM_ROOT" fetch "$r" --prune --quiet 2>/dev/null; then
    echo "fm-fork-sync: fetch $r failed (offline or unreachable); nothing changed" >&2
    exit 2
  fi
done

# Resolve the branch only after refreshing both remotes. An explicit branch is
# authoritative; otherwise the target remote's current HEAD is authoritative.
if [ -z "$BRANCH" ]; then
  if ! BRANCH=$(remote_default_branch "$FM_ROOT" "$TO"); then
    echo "fm-fork-sync: could not resolve $TO's current default branch; nothing changed" >&2
    exit 2
  fi
else
  if ! refresh_remote_tracking_branch "$FM_ROOT" "$TO" "$BRANCH"; then
    echo "fm-fork-sync: could not refresh $TO/$BRANCH; nothing changed" >&2
    exit 2
  fi
fi
if ! refresh_remote_tracking_branch "$FM_ROOT" "$FROM" "$BRANCH"; then
  echo "fm-fork-sync: could not refresh $FROM/$BRANCH; nothing changed" >&2
  exit 2
fi

from_ref="$FROM/$BRANCH"
to_ref="$TO/$BRANCH"
from_sha=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$from_ref^{commit}" 2>/dev/null || true)
to_sha=$(git -C "$FM_ROOT" rev-parse --verify --quiet "$to_ref^{commit}" 2>/dev/null || true)
if [ -z "$from_sha" ]; then
  echo "fm-fork-sync: $from_ref does not exist on the original" >&2
  exit 2
fi
if [ -z "$to_sha" ]; then
  echo "fm-fork-sync: $to_ref does not exist on the fork" >&2
  exit 2
fi

short() { git -C "$FM_ROOT" rev-parse --short "$1"; }
from_short=$(short "$from_sha")
to_short=$(short "$to_sha")
count_range() {
  local range=$1 count
  if ! count=$(git -C "$FM_ROOT" rev-list --count "$range" 2>/dev/null); then
    echo "fm-fork-sync: could not count commit range $range; nothing changed" >&2
    return 2
  fi
  case "$count" in
    ''|*[!0-9]*)
      echo "fm-fork-sync: invalid commit count '$count' for range $range; nothing changed" >&2
      return 2
      ;;
  esac
  printf '%s' "$count"
}

is_ancestor() {
  local older=$1 newer=$2 status
  git -C "$FM_ROOT" merge-base --is-ancestor "$older" "$newer" 2>/dev/null
  status=$?
  if [ "$status" -eq 0 ]; then
    return 0
  fi
  if [ "$status" -eq 1 ]; then
    return 1
  fi
  echo "fm-fork-sync: could not determine whether $older is an ancestor of $newer; nothing changed" >&2
  return 2
}

# --- decide and act --------------------------------------------------------

if [ "$from_sha" = "$to_sha" ]; then
  echo "up to date: $to_ref already matches $from_ref ($from_short)"
  exit 0
fi

if is_ancestor "$to_sha" "$from_sha"; then
  # Fork branch is behind the original with NO commits of its own: a clean
  # fast-forward of the fork's branch to the original's tip.
  n=$(count_range "$to_sha..$from_sha") || exit 2
  if [ "$APPLY" != yes ]; then
    echo "fast-forward available: $to_ref can advance $to_short..$from_short ($n commit(s)); run with --apply to feed the fork"
    exit 0
  fi
  # Non-forced fast-forward push. The remote branch must still be an ancestor of
  # from_sha at push time or git refuses it - we never pass --force.
  if git -C "$FM_ROOT" push "$TO" "$from_sha:refs/heads/$BRANCH" >/dev/null 2>&1; then
    echo "updated: fast-forwarded $to_ref $to_short..$from_short ($n commit(s) from $FROM)"
    exit 0
  fi
  echo "fm-fork-sync: fast-forward push of $to_ref was refused (the fork moved under us); nothing forced" >&2
  exit 2
else
  RELATION_STATUS=$?
  [ "$RELATION_STATUS" -eq 1 ] || exit 2
fi

if is_ancestor "$from_sha" "$to_sha"; then
  # Fork branch already contains everything the original has, plus its own work.
  # The original has nothing new to feed.
  n=$(count_range "$from_sha..$to_sha") || exit 2
  echo "up to date: $to_ref is ahead of $from_ref by $n own commit(s); the original has nothing new to feed"
  exit 0
else
  RELATION_STATUS=$?
  [ "$RELATION_STATUS" -eq 1 ] || exit 2
fi

# Genuine divergence: the original has commits the fork lacks AND the fork has
# commits the original lacks. A fast-forward would discard the fork's own work,
# so we never do it. Publish (or describe) an integration branch at the
# original's tip for a reviewed merge instead.
ahead=$(count_range "$to_sha..$from_sha") || exit 2
own=$(count_range "$from_sha..$to_sha") || exit 2
integ="integrate-upstream-$from_short"
if [ "$APPLY" != yes ]; then
  echo "diverged: $from_ref has $ahead commit(s) the fork lacks and $to_ref has $own of its own; run with --apply to publish integration branch $TO/$integ for a reviewed merge (the fork's own commits are never discarded)"
  exit 0
fi
if git -C "$FM_ROOT" push "$TO" "$from_sha:refs/heads/$integ" >/dev/null 2>&1; then
  echo "integration branch: pushed $TO/$integ at $from_short; open a reviewed PR into $BRANCH to bring in the original's $ahead commit(s) without discarding the fork's $own own commit(s). Nothing was force-pushed."
  exit 0
fi
echo "fm-fork-sync: could not publish integration branch $TO/$integ (it may already exist at a different commit); nothing forced" >&2
exit 2
