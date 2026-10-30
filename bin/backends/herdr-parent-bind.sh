#!/usr/bin/env bash
# bin/backends/herdr-parent-bind.sh - fork-local Herdr parent identity.
#
# docs/herdr-backend.md "Firstmate running outside Herdr" is the behavior
# contract. This file is its only implementation. The binding record is
# FM_HOME/state/herdr-parent-<URI-encoded-session>.json. Nothing in this file
# writes under the tracked code root.
#
# Sourced by bin/backends/herdr.sh. A missing or unloaded copy must fail the
# adapter load. It must not fall through to creating a role-labeled workspace.
# shellcheck shell=bash

# fm_backend_herdr_workspace_inventory: read one workspace list and prove it
# names each workspace exactly once. Prints the JSON body.
# Returns 1 when the CLI fails, the body is not a workspace array, an id is
# missing, or any workspace_id is repeated. An empty array is a proven empty
# inventory. It never creates a workspace.
fm_backend_herdr_workspace_inventory() {  # <session>
  local session=$1 list
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '
    (.result.workspaces | type) == "array"
    and all(.result.workspaces[];
      (. | type) == "object"
      and (.workspace_id | type) == "string"
      and (.workspace_id | length) > 0)
    and (([.result.workspaces[].workspace_id] | unique | length)
      == (.result.workspaces | length))
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$list"
}

fm_backend_herdr_bound_parent_id() {  # <session> <workspace-list-json>
  local session=$1 list=$2 home state journal journal_session journal_home parent
  local id="" count base task_id meta binding key
  local meta_session meta_workspace meta_tab meta_pane
  [ -n "${FM_HOME:-}" ] || return 2
  home=$(fm_backend_herdr_projection_home_identity "$FM_HOME" 2>/dev/null) || return 2
  state="${FM_HOME%/}/state"
  [ ! -L "$state" ] || return 1
  [ -d "$state" ] || return 2
  key=$(printf '%s' "$session" | jq -sRr @uri) || return 1
  binding="$state/herdr-parent-$key.json"
  if [ -e "$binding" ] || [ -L "$binding" ]; then
    [ -f "$binding" ] && [ ! -L "$binding" ] || return 1
    parent=$(jq -er --arg home "$home" --arg session "$session" '
      select(.version == 1 and .home == $home and .session == $session)
      | .parent_workspace_id | select(type == "string" and test("^[A-Za-z0-9:_-]+$"))
    ' "$binding") || return 1
    id=$parent
  fi
  for journal in "$state"/*.herdr-presentation; do
    [ -f "$journal" ] && [ ! -L "$journal" ] || continue
    base=$(basename "$journal")
    case "$base" in
      *"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX")
        task_id=${base%"$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"}
        ;;
      *) continue ;;
    esac
    fm_backend_herdr_projection_journal_snapshot "$journal" "$task_id" >/dev/null 2>&1 || continue
    [ "$FM_BACKEND_HERDR_JOURNAL_VERSION" = 2 ] || continue
    journal_session=$FM_BACKEND_HERDR_JOURNAL_SESSION
    [ "$journal_session" = "$session" ] || continue
    journal_home=$FM_BACKEND_HERDR_JOURNAL_HOME
    [ "$journal_home" = "$home" ] || continue
    parent=$FM_BACKEND_HERDR_JOURNAL_PARENT_WORKSPACE_ID
    case "$parent" in
      ''|*[!A-Za-z0-9:_-]*) return 1 ;;
    esac
    meta="$state/$task_id.meta"
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    meta_session=$(fm_backend_herdr_projection_journal_field "$meta" herdr_session 2>/dev/null) || continue
    meta_workspace=$(fm_backend_herdr_projection_journal_field "$meta" herdr_workspace_id 2>/dev/null) || continue
    meta_tab=$(fm_backend_herdr_projection_journal_field "$meta" herdr_tab_id 2>/dev/null) || continue
    meta_pane=$(fm_backend_herdr_projection_journal_field "$meta" herdr_pane_id 2>/dev/null) || continue
    [ "$meta_session" = "$journal_session" ] || continue
    [ "$meta_workspace" = "$FM_BACKEND_HERDR_JOURNAL_WORKSPACE_ID" ] || continue
    [ "$meta_tab" = "$FM_BACKEND_HERDR_JOURNAL_TAB_ID" ] || continue
    [ "$meta_pane" = "$FM_BACKEND_HERDR_JOURNAL_PANE_ID" ] || continue
    [ -z "$id" ] || [ "$id" = "$parent" ] || return 1
    id=$parent
  done
  [ -n "$id" ] || return 2
  count=$(printf '%s' "$list" | jq -r --arg id "$id" \
    '[.result.workspaces[]? | select(.workspace_id == $id and (.label | type) == "string")] | length') || return 1
  [ "$count" = 1 ] || return 1
  printf '%s' "$id"
}

fm_backend_herdr_parent_bind() {
  local session=$1 parent=$2 list=$3 home state key binding existing status tmp
  [ -n "${FM_HOME:-}" ] || return 1
  case "$parent" in ''|*[!A-Za-z0-9:_-]*) return 1 ;; esac
  home=$(fm_backend_herdr_projection_home_identity "$FM_HOME") || return 1
  state="${FM_HOME%/}/state"
  [ ! -L "$state" ] || return 1
  mkdir -p "$state" || return 1
  status=0
  existing=$(fm_backend_herdr_bound_parent_id "$session" "$list") || status=$?
  case "$status" in
    0) [ "$existing" = "$parent" ] || return 1 ;;
    2) ;;
    *) return 1 ;;
  esac
  printf '%s' "$list" | jq -e --arg id "$parent" '
    [.result.workspaces[]? | select(.workspace_id == $id and (.label | type) == "string")] | length == 1
  ' >/dev/null || return 1
  key=$(printf '%s' "$session" | jq -sRr @uri) || return 1
  binding="$state/herdr-parent-$key.json"
  [ ! -e "$binding" ] && [ ! -L "$binding" ] || return 0
  tmp=$(mktemp "$state/.herdr-parent.XXXXXX") || return 1
  if ! jq -n --arg home "$home" --arg session "$session" --arg parent "$parent" \
    '{version:1, home:$home, session:$session, parent_workspace_id:$parent}' > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ln "$tmp" "$binding" 2>/dev/null; then
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  existing=$(fm_backend_herdr_bound_parent_id "$session" "$list") || return 1
  [ "$existing" = "$parent" ]
}

# Prints the workspace id to adopt, or nothing when the caller must create one.
# Returns 0 for either success, and 3 when placement must refuse.
# The proven list is kept in FM_BACKEND_HERDR_PARENT_INVENTORY for the create bind.
fm_backend_herdr_parent_resolve_flat() {  # <session> <role-label>
  local session=$1 label=$2 list wsid matches count bound_status
  FM_BACKEND_HERDR_PARENT_INVENTORY=""
  list=$(fm_backend_herdr_workspace_inventory "$session") || {
    echo "error: herdr workspace list for session '$session' is unreadable or does not prove a unique workspace inventory; refusing to create a workspace labeled '$label'" >&2
    return 3
  }
  FM_BACKEND_HERDR_PARENT_INVENTORY=$list
  bound_status=0
  wsid=$(fm_backend_herdr_bound_parent_id "$session" "$list") || bound_status=$?
  case "$bound_status" in
    0) ;;
    2)
      matches=$(printf '%s' "$list" | jq -r --arg want "$label" \
        '.result.workspaces[]? | select(.label == $want) | .workspace_id') || {
        echo "error: herdr workspace list for session '$session' is unreadable or does not prove a unique workspace inventory; refusing to create a workspace labeled '$label'" >&2
        return 3
      }
      count=$(printf '%s' "$matches" | grep -c '[^[:space:]]' || true)
      if [ "$count" -gt 1 ]; then
        echo "error: ${count} herdr workspaces in session '$session' are labeled '$label' (${matches//$'\n'/ }) and this spawn has no herdr parent pane to identify which one is its own; rename or close the extras, or run firstmate inside the workspace its workers belong in" >&2
        return 3
      fi
      wsid=${matches%%$'\n'*}
      ;;
    *)
      echo "error: herdr home label '$label' matches no workspace in session '$session', and this home's recorded parent workspaces do not agree on one live workspace; refusing to create another workspace labeled '$label'" >&2
      return 3
      ;;
  esac
  if [ -n "$wsid" ]; then
    fm_backend_herdr_parent_bind "$session" "$wsid" "$list" || return 3
    printf '%s' "$wsid"
  fi
}

fm_backend_herdr_parent_bind_created() {  # <session> <workspace-id> <role-label>
  local session=$1 id=$2 label=$3 list
  [ -n "${FM_BACKEND_HERDR_PARENT_INVENTORY:-}" ] || return 1
  list=$(printf '%s' "$FM_BACKEND_HERDR_PARENT_INVENTORY" | jq --arg id "$id" --arg label "$label" \
    '.result.workspaces += [{workspace_id:$id,label:$label}]') || return 1
  fm_backend_herdr_parent_bind "$session" "$id" "$list"
}

# fm_backend_herdr_projection_parent_workspace_exact: resolve one exact parent
# workspace. Prints "<workspace-id>\t<live-label>".
# A parent proven by this home's durable binding or validated journals wins, including when
# another workspace still carries <parent-label>. The role label is the
# fallback only when no proven parent is recorded, and only when it matches
# exactly one workspace. Disagreeing parent records and an unreadable
# inventory refuse. The printed label is the workspace's current label, which
# can differ from <parent-label> after a rename. A label is never enough to
# create a parent.
fm_backend_herdr_projection_parent_workspace_exact() {  # <session> <parent-label> [<recorded-parent-id>]
  local session=$1 parent_label=$2 recorded=${3:-} list id live status
  list=$(fm_backend_herdr_workspace_inventory "$session") || return 1
  status=0
  id=$(fm_backend_herdr_bound_parent_id "$session" "$list") || status=$?
  case "$status" in
    0) [ -z "$recorded" ] || [ "$id" = "$recorded" ] || return 1 ;;
    1) return 1 ;;
    2)
      if [ -n "$recorded" ]; then
        id=$recorded
      else
        id=$(printf '%s' "$list" | jq -er --arg label "$parent_label" '
          [.result.workspaces[] | select(.label == $label)]
          | if length == 1 then .[0].workspace_id else empty end
        ') || return 1
      fi
      ;;
  esac
  live=$(printf '%s' "$list" | jq -er --arg id "$id" '
    [.result.workspaces[] | select(.workspace_id == $id)]
    | if length == 1 and (.[0].label | type) == "string" then .[0].label else empty end
  ') || return 1
  fm_backend_herdr_parent_bind "$session" "$id" "$list" || return 1
  printf '%s\t%s' "$id" "$live"
}
