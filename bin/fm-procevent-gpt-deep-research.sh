#!/usr/bin/env bash
# GPT Deep Research adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-gpt-deep-research.sh arm <watch-id> [--state-dir <dir>] [--interval-seconds <n>]
#   fm-procevent-gpt-deep-research.sh poll <watch-id> [--state-dir <dir>] [--interval-seconds <n>]
#   fm-procevent-gpt-deep-research.sh terminal <result-file>
#   fm-procevent-gpt-deep-research.sh source-id <watch-id>
#   fm-procevent-gpt-deep-research.sh retire <watch-id>
#
# --state-dir defaults to the installed gpt-deep-research skill's own
# resolve_watches_dir() (~/.claude/skills/gpt-deep-research/scripts/state_paths.py),
# never a value duplicated here, so it never silently drifts from wherever the
# skill is actually writing watches this session.
#
# poll     The blocking child bin/fm-procevent.sh supervises. Reads the named
#          gpt-deep-research report-watch state file on a fixed interval and
#          exits 0 with one JSON result line the first time that watch reaches
#          a status the report_watcher.py script itself treats as no longer
#          actively progressing collection: COLLECTED, COLLECTED_CLEANUP_PENDING,
#          NEEDS_COLLECTION, BLOCKED, or COLLECTION_UNCERTAIN (its own
#          TERMINAL_STATUSES set, plus COLLECTED_CLEANUP_PENDING because the
#          archive is already final once that status appears - only the
#          watcher's own best-effort tab close is still retrying). A watch
#          file that never appears, or that vanishes after appearing, is a
#          captured error result rather than an infinite wait.
# terminal Exit 0 always: a gpt-deep-research watch is single-shot by design
#          (report_watcher.py registers one watch per Deep Research run), so
#          any captured poll result is that source's only and final result.
#
# This adapter is deliberately thin and read-only against a state format it
# does not own. It never starts, arms, or registers a Deep Research run, never
# writes to the gpt-deep-research skill's own watch state, and never touches
# Chrome. It only reads the `gpt_deep_research_report_watch.v1` JSON schema
# report_watcher.py already maintains independently (normally via its own
# launchd job), so the existing standalone watcher keeps working unmodified
# whether or not this adapter is armed. Ownership, durable capture,
# publication, and restart recovery all belong to bin/fm-procevent.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

GDR_SKILL_SCRIPTS="$HOME/.claude/skills/gpt-deep-research/scripts"
DEFAULT_INTERVAL=15
# The result carries no more information than the watch file's own terminal
# fields, so it never becomes stale mid-poll from an unrelated wait.
MAX_MISSING_POLLS=4

die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# The watches directory is owned once by the gpt-deep-research skill's own
# state_paths.py (XDG_STATE_HOME primary, ~/.openclaw legacy fallback while
# empty). This adapter never re-derives that resolution itself - a duplicated
# copy would silently drift the moment the skill's own default changes, per
# firstmate-coding-guidelines' one-owner rule. --state-dir always wins; absent
# that, ask the installed skill directly and fail loudly rather than guess.
default_state_dir() {
  [ -f "$GDR_SKILL_SCRIPTS/state_paths.py" ] \
    || die "no --state-dir given and $GDR_SKILL_SCRIPTS/state_paths.py is missing; pass --state-dir explicitly"
  PYTHONPATH="$GDR_SKILL_SCRIPTS" python3 -c '
from state_paths import resolve_watches_dir
print(resolve_watches_dir())
' 2>/dev/null || die "could not resolve the gpt-deep-research watches directory; pass --state-dir explicitly"
}
usage() { sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

cmd_source_id() {
  local watch_id=${1-}
  [ -n "$watch_id" ] || usage
  case "$watch_id" in *$'\n'*) die "watch id cannot contain newlines" ;; esac
  fm_procevent_source_id_valid "gpt-deep-research-$watch_id" \
    || die "not a valid source id once prefixed: $watch_id"
  printf 'gpt-deep-research-%s\n' "$watch_id"
}

parse_opts() {  # <argv...> -> sets WATCH_ID, STATE_DIR, INTERVAL
  WATCH_ID=${1-}
  [ -n "$WATCH_ID" ] || usage
  shift
  case "$WATCH_ID" in *$'\n'*) die "watch id cannot contain newlines" ;; esac
  STATE_DIR=""
  INTERVAL="$DEFAULT_INTERVAL"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --state-dir)
        [ "$#" -ge 2 ] || die "--state-dir needs a value"
        STATE_DIR=$2; shift 2 ;;
      --interval-seconds)
        [ "$#" -ge 2 ] || die "--interval-seconds needs a value"
        case "$2" in ''|*[!0-9]*) die "--interval-seconds must be a positive integer" ;; esac
        INTERVAL=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  [ -n "$STATE_DIR" ] || STATE_DIR=$(default_state_dir) || exit 1
}

cmd_arm() {
  parse_opts "$@"
  local id
  id=$(cmd_source_id "$WATCH_ID") || exit 1
  [ -f "$STATE_DIR/$WATCH_ID.json" ] \
    || printf 'warning: no watch file yet at %s/%s.json; polling will wait for it\n' "$STATE_DIR" "$WATCH_ID" >&2
  "$SCRIPT_DIR/fm-procevent.sh" register gpt-deep-research "$id" -- \
    "${BASH_SOURCE[0]}" poll "$WATCH_ID" --state-dir "$STATE_DIR" --interval-seconds "$INTERVAL" \
    || exit 1
  printf 'armed: %s\n' "$id"
  printf 'watch-file: %s/%s.json\n' "$STATE_DIR" "$WATCH_ID"
}

cmd_retire() {
  local watch_id=${1-} id
  [ -n "$watch_id" ] || usage
  id=$(cmd_source_id "$watch_id") || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" retire "$id"
}

# report_watcher.py's own TERMINAL_STATUSES, plus COLLECTED_CLEANUP_PENDING:
# once that status appears the archive_path is already final, only the
# best-effort tab close is still being retried by report_watcher.py itself.
is_ready_status() {
  case "$1" in
    COLLECTED|COLLECTED_CLEANUP_PENDING|NEEDS_COLLECTION|BLOCKED|COLLECTION_UNCERTAIN) return 0 ;;
    *) return 1 ;;
  esac
}

emit_result() {  # <status> <watch-file> [note]
  local status=$1 file=$2 note=${3-}
  python3 -c '
import json, sys
status, path, note = sys.argv[1], sys.argv[2], sys.argv[3]
state = {}
try:
    with open(path, encoding="utf-8") as fh:
        state = json.load(fh)
except (OSError, ValueError):
    pass
print(json.dumps({
    "schema": "gpt_deep_research_procevent_result.v1",
    "watch_status": status,
    "watch_file": path,
    "slug": state.get("slug"),
    "expected_url": state.get("expected_url"),
    "archive_path": state.get("archive_path"),
    "last_error": state.get("last_error"),
    "note": note or None,
}, sort_keys=True))
' "$status" "$file" "$note"
}

cmd_poll() {
  parse_opts "$@"
  local file="$STATE_DIR/$WATCH_ID.json" missing=0 status
  while :; do
    if [ -f "$file" ]; then
      missing=0
      status=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        print(json.load(fh).get("status", ""))
except (OSError, ValueError):
    print("")
' "$file")
      if [ -n "$status" ] && is_ready_status "$status"; then
        emit_result "$status" "$file"
        return 0
      fi
    else
      missing=$((missing + 1))
      if [ "$missing" -ge "$MAX_MISSING_POLLS" ]; then
        emit_result "MISSING" "$file" "watch file never appeared or was removed after $((missing * INTERVAL))s"
        return 0
      fi
    fi
    sleep "$INTERVAL"
  done
}

cmd_terminal() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] || die "result file does not exist: $file"
  return 0
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
