#!/usr/bin/env bash
# Behavior tests for the GPT Deep Research adapter of the process-to-event
# runner (bin/fm-procevent-gpt-deep-research.sh).
#
# Every scenario is exercised through the adapter's public commands, a real
# watch-state JSON file on disk, and the generic runner where end-to-end wake
# delivery is asserted; nothing here asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-gpt-deep-research-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

pe()  { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
gdr() { FM_HOME="$1" "$ROOT/bin/fm-procevent-gpt-deep-research.sh" "${@:2}"; }

# A disposable home for command invocations below that never register or
# retire anything (source-id, poll, terminal), so they need no real fleet
# state but still need FM_HOME to resolve to a directory.
STANDALONE_HOME="$TMP_ROOT/h-standalone"
mkdir -p "$STANDALONE_HOME/state"

GDR_HOMES=()
gdr_teardown() {
  local home
  for home in ${GDR_HOMES[@]+"${GDR_HOMES[@]}"}; do
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap gdr_teardown EXIT

new_home() { mkdir -p "$1/state"; GDR_HOMES+=("$1"); }

first_result() {  # <home> <source-id>
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result() {  # <home> <source-id> [tries]
  local n=${3:-100}
  for _ in $(seq 1 "$n"); do
    first_result "$1" "$2" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

write_watch() {  # <state-dir> <watch-id> <status> [archive-path]
  mkdir -p "$1"
  python3 -c '
import json, sys
sd, wid, status, archive = sys.argv[1:5]
json.dump({
    "schema": "gpt_deep_research_report_watch.v1",
    "watch_id": wid,
    "status": status,
    "slug": "test-slug",
    "expected_url": "https://chatgpt.com/c/test",
    "archive_path": archive or None,
    "last_error": None,
}, open(f"{sd}/{wid}.json", "w"))
' "$1" "$2" "$3" "${4-}"
}

# --- source-id is a stable, prefixed derivation of the watch id -------------
sid=$(gdr "$STANDALONE_HOME" source-id watch-abc123)
assert_contains "$sid" "gpt-deep-research-watch-abc123" "source-id prefixes the watch id"

# --- poll returns immediately for an already-ready watch --------------------
WD="$TMP_ROOT/watches-ready"
write_watch "$WD" watch-ready COLLECTED "$TMP_ROOT/report.md"
out=$(gdr "$STANDALONE_HOME" poll watch-ready --state-dir "$WD" --interval-seconds 5)
assert_contains "$out" '"watch_status": "COLLECTED"' "poll reports the ready status"
assert_contains "$out" "$TMP_ROOT/report.md" "poll carries the archive path through"

# --- poll treats COLLECTED_CLEANUP_PENDING as ready too, since the archive --
# is already final once that status appears (only tab-close cleanup remains).
WD2="$TMP_ROOT/watches-cleanup-pending"
write_watch "$WD2" watch-cleanup COLLECTED_CLEANUP_PENDING "$TMP_ROOT/report2.md"
out=$(gdr "$STANDALONE_HOME" poll watch-cleanup --state-dir "$WD2" --interval-seconds 5)
assert_contains "$out" '"watch_status": "COLLECTED_CLEANUP_PENDING"' \
  "poll treats cleanup-pending as a ready result"

# --- poll keeps waiting on a non-terminal status until it changes -----------
WD3="$TMP_ROOT/watches-progressing"
write_watch "$WD3" watch-progressing WATCHING
( sleep 1; write_watch "$WD3" watch-progressing COLLECTED "$TMP_ROOT/report3.md" ) &
BGPID=$!
out=$(gdr "$STANDALONE_HOME" poll watch-progressing --state-dir "$WD3" --interval-seconds 1)
wait "$BGPID"
assert_contains "$out" '"watch_status": "COLLECTED"' \
  "poll only returns once the watch reaches a ready status"

# --- a watch file that never appears is a captured MISSING result, not a ----
# silent infinite wait.
WD4="$TMP_ROOT/watches-empty"
out=$(gdr "$STANDALONE_HOME" poll watch-never-existed --state-dir "$WD4" --interval-seconds 1)
assert_contains "$out" '"watch_status": "MISSING"' \
  "poll reports MISSING instead of hanging forever on an absent watch file"

# --- terminal is always true: a gpt-deep-research watch is single-shot -----
RESULT_FILE="$TMP_ROOT/one-result.json"
printf '%s\n' "$out" > "$RESULT_FILE"
gdr "$STANDALONE_HOME" terminal "$RESULT_FILE"
assert_contains "$?" 0 "terminal always retires a single-shot watch source"

# --- end to end: arm + the generic runner delivers a real durable wake -----
H="$TMP_ROOT/h-e2e"; new_home "$H"
WD5="$H/watches"
write_watch "$WD5" watch-e2e WATCHING
out=$(gdr "$H" arm watch-e2e --state-dir "$WD5" --interval-seconds 1)
assert_contains "$out" "armed: gpt-deep-research-watch-e2e" "arm reports the canonical source id"
assert_present "$H/state/procevent/gpt-deep-research-watch-e2e.source" \
  "arm registers the process-event source"

( sleep 1; write_watch "$WD5" watch-e2e COLLECTED "$H/vault-report.md" ) &
BGPID=$!
pe "$H" start gpt-deep-research-watch-e2e >/dev/null 2>&1 &
wait_for_result "$H" gpt-deep-research-watch-e2e \
  || fail "no wake was ever published for the completed research run"
wait "$BGPID" 2>/dev/null || true
RESULT=$(first_result "$H" gpt-deep-research-watch-e2e)
assert_grep '"watch_status": "COLLECTED"' "$RESULT" \
  "the durable result records the collected status"
assert_grep "vault-report.md" "$RESULT" "the durable result carries the archive path"

for _ in $(seq 1 50); do
  [ -e "$H/state/procevent/gpt-deep-research-watch-e2e.source" ] || break
  sleep 0.1
done
assert_absent "$H/state/procevent/gpt-deep-research-watch-e2e.source" \
  "a captured single-shot result retires its own source registration"

printf 'all fm-procevent-gpt-deep-research tests passed\n'
