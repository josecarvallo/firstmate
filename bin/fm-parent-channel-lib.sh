#!/usr/bin/env bash
# fm-parent-channel-lib.sh - single owner of "which channel does THIS home use to
# escalate to its parent, and how is a line put there".
#
# A secondmate home has exactly one escalation channel toward its parent, and
# both directions of a decision must use it: the line that OPENS a decision and
# the line that CLOSES it. Opening in one channel and closing in another leaves
# the parent's open-decision fold showing an answered decision forever, which
# degrades the one surface the captain reads to know what is still waiting on
# them. Resolving the channel in one place is what makes the two directions
# provably the same channel.
#
# Route per bin/fm-secondmate-parent-lib.sh:
#   local   -> <parent_home>/state/<self>.status, the parent's own log. The
#              parent reads it directly, so a plain append is the delivery.
#   remote  -> <this home>/state/parent-replies.status, the mirror the parent's
#              ingest adapter copies into its own log at most once
#              (bin/fm-procevent-remote-reply.sh). A remote home cannot write
#              the parent's filesystem, so the mirror IS its channel.
#
# The tri-state return is the point of this library: callers must be able to
# tell "this home has no parent" apart from "this home has a parent but the
# channel cannot be resolved", because the first is normal for a primary home
# and the second must fail visibly rather than let a close land in the wrong
# channel in silence.
#
# This file is sourced and has no side effects on source.

_FM_PARENT_CHANNEL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_PARENT_CHANNEL_LIB_DIR="."
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-secondmate-parent-lib.sh"

# Read this home's secondmate identity marker.
# 0 + prints the id; 1 = no marker (a primary home); 2 = marker present but unusable.
fm_parent_channel_self_id() {  # <home>
  local marker="$1/.fm-secondmate-home" id
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  # bash's read drops NUL bytes and different generations disagree on the
  # result, so reject a NUL-bearing marker before trusting any id it names.
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  # Read the WHOLE marker, not just its first line: a marker carrying more than
  # one line is corrupt, and taking line one would route on a guess instead of
  # surfacing the corruption. Command substitution strips the trailing newline,
  # so a well-formed single-line marker passes and anything else keeps an
  # embedded newline that the charset check below rejects.
  id=$(cat "$marker" 2>/dev/null) || return 2
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 2 ;;
  esac
  printf '%s\n' "$id"
}

# Resolve this home's parent escalation channel.
# 0 + prints the absolute destination path; 1 = this home has no parent;
# 2 = this home has a parent but its channel cannot be resolved (fail visibly).
fm_parent_channel_path() {  # <home> <state-dir>
  local home=$1 state=$2 self rc=0 path
  self=$(fm_parent_channel_self_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # An identified secondmate home with no readable parent binding is the
  # unresolvable case, never the no-parent case: it HAS a parent by definition.
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 2
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 2
      # The home itself must exist - a binding naming a moved or deleted parent
      # is unresolvable, not a silent no-op. Its state/ dir need not exist yet;
      # the append creates it, exactly as the pre-existing cross-home writer did.
      [ -d "$FM_SECONDMATE_PARENT_HOME" ] || return 2
      path="$FM_SECONDMATE_PARENT_HOME/state/$self.status"
      ;;
    remote)
      [ -n "$state" ] || return 2
      path="$state/parent-replies.status"
      ;;
    *) return 2 ;;
  esac
  # A symlinked channel is unresolvable, not empty. status_open_decisions
  # refuses to read one and would fold it to "no open keys", so a caller that
  # only checked the fold would close its local copy and strand the upstream one
  # in silence - exactly the asymmetry this library exists to prevent.
  [ ! -L "$path" ] || return 2
  printf '%s\n' "$path"
}

# Append one line to a parent channel at most once.
# A replayed close, a retried escalation, and the mate's own belt-and-braces
# repeat must all converge on one line rather than stack duplicates in the
# parent's log. A symlinked destination is refused rather than followed out of
# the state directory.
fm_parent_channel_append_once() {  # <path> <line>
  local path=$1 line=$2 dir
  [ -n "$path" ] || return 1
  [ ! -L "$path" ] || return 1
  dir=$(dirname "$path")
  mkdir -p "$dir" 2>/dev/null || return 1
  [ -d "$dir" ] || return 1
  if grep -Fqx -- "$line" "$path" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$path"
}
