#!/usr/bin/env bash
# Single owner of the delivery-mode fact used by base selection: whether a task
# opens a pull request against origin.
#
# Spawn uses it before choosing a pooled worktree base, promotion uses it when a
# scout first acquires a delivery contract, and review-diff uses it to choose the
# matching comparison base. Keep the mode list here so those three consumers
# cannot drift independently.

fm_delivery_opens_pull_request() {  # <mode>
  case "$1" in
    no-mistakes|direct-PR) return 0 ;;
    *) return 1 ;;
  esac
}
