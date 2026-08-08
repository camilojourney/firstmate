#!/usr/bin/env bash
# Shared owner of the watcher's native push-transition escalation.
#
# The watcher and event-wait smoke tests source this library instead of loading
# the whole watcher to obtain handle_push_transition. Its source list is limited
# to the four production boundaries the transition handler actually calls.

FM_PUSH_TRANSITION_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-wake-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-transition-lib.sh
. "$FM_PUSH_TRANSITION_LIB_DIR/fm-transition-lib.sh"

TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}
FM_WAKE_POST_OUTPUT_ACTION=
FM_WATCH_DELIVERY_PID=
FM_WATCH_DELIVERY_IDENTITY=
WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"
WATCH_DELIVERY_MAX_BYTES=${FM_WATCH_DELIVERY_MAX_BYTES:-65536}
WATCH_DELIVERY_KEEP_LINES=${FM_WATCH_DELIVERY_KEEP_LINES:-64}
WATCH_DELIVERY_RETENTION_SECS=${FM_WATCH_DELIVERY_RETENTION_SECS:-3600}
case "$WATCH_DELIVERY_MAX_BYTES" in ''|*[!0-9]*|0) WATCH_DELIVERY_MAX_BYTES=65536 ;; esac
case "$WATCH_DELIVERY_KEEP_LINES" in ''|*[!0-9]*|0) WATCH_DELIVERY_KEEP_LINES=64 ;; esac
case "$WATCH_DELIVERY_RETENTION_SECS" in ''|*[!0-9]*|0) WATCH_DELIVERY_RETENTION_SECS=3600 ;; esac

watch_delivery_compact() {
  local now cutoff tmp fresh stale lines size
  [ -f "$WATCH_DELIVERY_LOG" ] || return 0
  now=$(date +%s)
  cutoff=$((now - WATCH_DELIVERY_RETENTION_SECS))
  tmp="$WATCH_DELIVERY_LOG.tmp.$FM_WATCH_DELIVERY_PID"
  fresh="$tmp.fresh"
  stale="$tmp.stale"
  : > "$fresh" 2>/dev/null || return 0
  : > "$stale" 2>/dev/null || return 0
  awk -F '\t' -v cutoff="$cutoff" -v fresh="$fresh" -v stale="$stale" '
    $4 ~ /^[0-9]+$/ {
      if ($4 >= cutoff) {
        print >> fresh
      } else {
        print >> stale
      }
      next
    }
    { print >> fresh }
    END {
      close(fresh)
      close(stale)
    }
  ' "$WATCH_DELIVERY_LOG" 2>/dev/null || return 0
  cat "$stale" "$fresh" > "$tmp" 2>/dev/null || return 0
  lines=$(wc -l < "$tmp" 2>/dev/null | tr -d '[:space:]')
  case "$lines" in
    ''|*[!0-9]*) lines=0 ;;
  esac
  if [ "$lines" -gt "$WATCH_DELIVERY_KEEP_LINES" ]; then
    tail -n "$WATCH_DELIVERY_KEEP_LINES" "$tmp" 2>/dev/null > "$tmp.lines" 2>/dev/null \
      && mv -f "$tmp.lines" "$tmp" 2>/dev/null
  fi
  size=$(wc -c < "$tmp" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) size=0 ;;
  esac
  if [ "$size" -gt "$WATCH_DELIVERY_MAX_BYTES" ]; then
    tail -c "$WATCH_DELIVERY_MAX_BYTES" "$tmp" 2>/dev/null > "$tmp.bytes" 2>/dev/null \
      && awk 'NR > 1 || /^[0-9]+\t/' "$tmp.bytes" > "$tmp" 2>/dev/null
  fi
  mv -f "$tmp" "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  rm -f "$tmp" "$tmp.lines" "$tmp.bytes" "$fresh" "$stale" 2>/dev/null || true
}

watch_delivery_clean_identity() {
  printf '%s' "$1" | tr '\t\r\n' '   '
}

watch_delivery_clean_reason() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-4096
}

watch_delivery_publish() {
  local reason=$1 i
  [ -n "$FM_WATCH_DELIVERY_PID" ] || return 0
  [ -n "$FM_WATCH_DELIVERY_IDENTITY" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    sleep 0.02
    i=$((i + 1))
  done
  printf '%s\t%s\t%s\t%s\n' \
    "$FM_WATCH_DELIVERY_PID" \
    "$(watch_delivery_clean_identity "$FM_WATCH_DELIVERY_IDENTITY")" \
    "$(watch_delivery_clean_reason "$reason")" \
    "$(date +%s)" >> "$WATCH_DELIVERY_LOG" 2>/dev/null || true
  if [ -f "$WATCH_DELIVERY_LOG" ]; then
    watch_delivery_compact
  fi
  fm_lock_release "$WATCH_DELIVERY_LOCK"
}

# Append one bounded best-effort line for an absorbed supervision event.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

# Exit after reporting one actionable wake. Tests override this callback.
wake() {
  local output_status=0
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  trap '' HUP INT TERM
  [ -z "$FM_WAKE_POST_OUTPUT_ACTION" ] || trap '' PIPE
  if echo "$1"; then
    output_status=0
    watch_delivery_publish "$1" || true
  else
    output_status=1
  fi
  if [ -n "$FM_WAKE_POST_OUTPUT_ACTION" ]; then
    "$FM_WAKE_POST_OUTPUT_ACTION" "$output_status" || true
  fi
  [ "$output_status" -eq 0 ] || exit "$output_status"
  exit 0
}

_hb_surfaced_path() {
  printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"
}

# Record a captain-relevant status after its durable wake has been enqueued.
mark_surfaced() {  # <status-file>
  local f=$1 task last
  task=$(basename "$f"); task="${task%.status}"
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  printf '%s' "$last" > "$(_hb_surfaced_path "$task")"
}

# Act on a fresh actionable transition from a push-capable backend.
handle_push_transition() {  # <backend> <session> <record>
  local backend=$1 session=$2 record=$3 pane_id to window task reason
  pane_id=$(fm_transition_pane_id "$record")
  to=$(fm_transition_to_status "$record")
  [ -n "$pane_id" ] || { sleep 1; return; }
  window="$session:$pane_id"
  task=$(window_to_task "$window" "$STATE")
  if status_is_paused "$(last_status_line "$STATE/$task.status")"; then
    triage_log "absorbed push $to (declared pause, awaiting external): $window"
    fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
    return
  fi
  reason="stale: $window (herdr: agent $to - waiting on human, escalated immediately, not via wedge timer)"
  fm_wake_append stale "$window" "$reason" || exit 1
  fm_backend_commit_transition "$backend" "$STATE" "$session" "$record" || exit 1
  mark_surfaced "$STATE/$task.status"
  wake "$reason"
}
