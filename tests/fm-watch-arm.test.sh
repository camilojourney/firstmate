#!/usr/bin/env bash
# tests/fm-watch-arm.test.sh - the arm layer's cycle-close contract when the arm
# did not own the cycle.
#
# The watcher prints its one reason line to its OWN stdout, so only the arm that
# forked it ever reads that line. An arm that ATTACHED to an existing cycle holds
# no handle on it and can observe only a released lock, which is why a completely
# successful cycle used to be reported as
# "watcher: FAILED - cycle ended without an actionable reason" on every harness
# whose protocol reads that line. These are real-process tests: a real
# bin/fm-watch.sh holds the singleton, a real bin/fm-watch-arm.sh attaches to it,
# and a real status change drives a real wake through the watcher-bound delivery
# record and durable queue.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-arm-tests)

# Both starters background a real process the test later waits on, so they set a
# global instead of echoing: a command substitution would make the pid a child of
# a subshell this shell can no longer wait for.
SEED_PID=
ARM_PID=

# Start the real watcher as the singleton holder.
start_seed_watcher() {  # <state> <fakebin> <watch-out>
  local state=$1 fakebin=$2 out=$3 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=5 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  SEED_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
      && [ -e "$state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$SEED_PID" ] \
    || fail "seed watcher did not take the lock"
}

# Attach a real arm to the live cycle.
start_attached_arm() {  # <state> <fakebin> <arm-out> <confirm-timeout>
  local state=$1 fakebin=$2 armout=$3 confirm=$4 i
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_ARM_ATTACH_POLL=0.1 \
    FM_ARM_CONFIRM_TIMEOUT="$confirm" "$WATCH_ARM" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 80 ]; do
    grep -qF "watcher: attached pid=$SEED_PID" "$armout" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "watcher: attached pid=$SEED_PID" "$armout" \
    || fail "arm did not attach to the live watcher: $(cat "$armout")"
}

test_attached_arm_reports_the_delivered_wake() {
  local dir state fakebin out armout status
  dir=$(make_case attached-delivered-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A real captain-relevant status change: the watcher records it in the durable
  # queue, prints its one reason line to its own stdout, and exits.
  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$out" || fail "seed watcher did not surface the signal wake: $(cat "$out")"

  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -q 'demo.status' "$state/.wake-queue" \
    || fail "the wake was not durably recorded, so this case proves nothing"
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported a delivered wake as a failed cycle: $(cat "$armout")"
  grep -qF 'watcher: cycle closed actionably (reason delivered by its owner arm)' "$armout" \
    || fail "attached arm did not report the owner-delivered close: $(cat "$armout")"
  grep -qF "$SEED_PID" "$state/.watch-deliveries.log" \
    || fail "the delivered wake record was not retained for later observers: $(cat "$state/.watch-deliveries.log")"
  expect_code 0 "$status" "an attached arm whose cycle delivered a wake must close successfully"
  grep -q 'reason=attached-delivered-wake' "$state/.watch-cycle-exits.log" \
    || fail "the delivered-wake close was not classified in the lifecycle ledger"
  pass "watch-arm: an attached arm reports the wake its cycle delivered instead of a false failure"
}

test_attached_arm_reports_the_delivered_wake_after_drain() {
  local dir state fakebin out armout status
  dir=$(make_case attached-drained-wake)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  # A wider confirmation budget keeps the arm in its successor wait while the
  # handling turn drains, which is the ordering this case exists to cover.
  start_attached_arm "$state" "$fakebin" "$armout" 5

  printf 'done: fixture finished\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  # The handling turn consumes the records before the attached arm closes: the
  # queue is empty again, while the watcher's identity-bound terminal record
  # still proves which cycle delivered the reason.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain failed"
  [ ! -s "$state/.wake-queue" ] || fail "drain left records behind"

  wait_for_exit "$ARM_PID" 200
  status=$?
  ! grep -qF 'watcher: FAILED' "$armout" \
    || fail "attached arm reported an already-handled wake as a failed cycle: $(cat "$armout")"
  grep -qF 'watcher: cycle closed actionably (reason delivered by its owner arm)' "$armout" \
    || fail "attached arm did not report the owner-delivered close after the queue drain: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm whose wake was already drained must close successfully"
  pass "watch-arm: a delivered wake consumed by the handling turn still closes the attached arm cleanly"
}

test_attached_arm_still_fails_on_a_wake_it_did_not_deliver() {
  local dir state fakebin out armout status
  dir=$(make_case attached-no-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  armout="$dir/arm.out"
  start_seed_watcher "$state" "$fakebin" "$out"
  start_attached_arm "$state" "$fakebin" "$armout" 1

  # A process-event producer advances the same home-wide queue while the
  # observed watcher remains uninvolved, so only watcher-bound evidence can
  # distinguish this from a delivered watcher cycle.
  append_wake "$state" check process-event "check: process-event result captured: fixture"
  kill "$SEED_PID" 2>/dev/null || true
  wait "$SEED_PID" 2>/dev/null || true
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: FAILED - cycle ended without an actionable reason' "$armout" \
    || fail "a cycle that delivered nothing must still fail loudly: $(cat "$armout")"
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] \
    || fail "arm did not exit nonzero for a cycle that delivered nothing (status $status)"
  pass "watch-arm: a cycle that delivered no wake of its own still fails loudly"
}

test_attached_arm_keeps_the_owner_delivery_readable_for_later_observers() {
  local dir state fakebin watchout armout1 armout2 pid1 pid2 status1 status2
  dir=$(make_case attached-shared-delivery)
  state="$dir/state"
  fakebin="$dir/fakebin"
  watchout="$dir/watch.out"
  armout1="$dir/arm1.out"
  armout2="$dir/arm2.out"
  start_seed_watcher "$state" "$fakebin" "$watchout"
  start_attached_arm "$state" "$fakebin" "$armout1" 5
  pid1=$ARM_PID
  start_attached_arm "$state" "$fakebin" "$armout2" 5
  pid2=$ARM_PID

  printf 'done: shared delivery fixture\n' > "$state/demo.status"
  wait_for_exit "$SEED_PID" 120
  grep -q '^signal:' "$watchout" || fail "seed watcher did not surface the shared wake: $(cat "$watchout")"

  wait_for_exit "$pid1" 120
  status2=$?
  wait_for_exit "$pid2" 120
  status1=$?
  grep -qF 'watcher: cycle closed actionably (reason delivered by its owner arm)' "$armout1" \
    || fail "first attached arm did not report the owner-delivered close: $(cat "$armout1")"
  grep -qF 'watcher: cycle closed actionably (reason delivered by its owner arm)' "$armout2" \
    || fail "second attached arm did not report the owner-delivered close: $(cat "$armout2")"
  [ "$status1" -eq 0 ] && [ "$status2" -eq 0 ] \
    || fail "shared delivery close was not successful for both attached arms"
  grep -qF "$SEED_PID" "$state/.watch-deliveries.log" \
    || fail "the shared delivery record was not retained for later observers: $(cat "$state/.watch-deliveries.log")"
  pass "watch-arm: shared delivery records stay readable for later attached observers"
}

test_watch_delivery_compacts_stale_records_without_losing_fresh_delivery() {
  local dir state fresh_ts stale_ts log_count log_bytes
  dir=$(make_case watch-delivery-compact)
  state="$dir/state"
  fresh_ts=$(date +%s)
  stale_ts=$((fresh_ts - 7200))
  printf '100\tarm-stale\tstale-one\t%s\n101\tarm-stale\tstale-two\t%s\n102\tarm-fresh\tfresh-one\t%s\n103\tarm-fresh\tfresh-two\t%s\n' \
    "$stale_ts" "$stale_ts" "$fresh_ts" "$fresh_ts" \
    > "$state/.watch-deliveries.log"

  FM_STATE_OVERRIDE="$state" FM_WATCH_DELIVERY_MAX_BYTES=128 FM_WATCH_DELIVERY_KEEP_LINES=1 \
    FM_WATCH_DELIVERY_RETENTION_SECS=3600 ROOT="$ROOT" bash -c '
    set -eu
    . "$ROOT/bin/fm-push-transition-lib.sh"
    FM_WATCH_DELIVERY_PID=999
    FM_WATCH_DELIVERY_IDENTITY="arm-fresh"
    watch_delivery_publish "fresh reason"
  '

  grep -qF 'fresh reason' "$state/.watch-deliveries.log" \
    || fail "the fresh delivery was dropped during compaction: $(cat "$state/.watch-deliveries.log")"
  grep -qF 'fresh-one' "$state/.watch-deliveries.log" \
    || fail "the oldest fresh row was evicted during compaction: $(cat "$state/.watch-deliveries.log")"
  grep -qF 'fresh-two' "$state/.watch-deliveries.log" \
    || fail "the latest fresh row should remain readable after compaction: $(cat "$state/.watch-deliveries.log")"
  ! grep -qF 'stale-one' "$state/.watch-deliveries.log" \
    || fail "the stale cap retained the oldest stale row: $(cat "$state/.watch-deliveries.log")"
  grep -qF 'stale-two' "$state/.watch-deliveries.log" \
    || fail "the newest stale row should remain after compaction: $(cat "$state/.watch-deliveries.log")"
  log_count=$(wc -l < "$state/.watch-deliveries.log" | tr -d '[:space:]')
  case "$log_count" in
    ''|*[!0-9]*) fail "could not count compacted delivery rows: $(cat "$state/.watch-deliveries.log")" ;;
  esac
  [ "$log_count" -eq 4 ] \
    || fail "compaction removed or retained the wrong delivery rows: $(cat "$state/.watch-deliveries.log")"
  pass "watch-delivery: stale records compact away while fresh rows remain readable"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_attached_arm_keeps_the_owner_delivery_readable_for_later_observers
test_watch_delivery_compacts_stale_records_without_losing_fresh_delivery
