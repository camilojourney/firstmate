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
  [ ! -s "$state/.watch-deliveries.log" ] \
    || fail "the delivered wake record was left behind after a direct close: $(cat "$state/.watch-deliveries.log")"
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

test_attached_arm_keeps_the_owner_delivery_until_it_is_read() {
  local dir state armdir armout pidfile allowfile watch_pid watch_identity status i
  dir=$(make_case attached-delivery-churn)
  state="$dir/state"
  armdir="$dir/bin"
  armout="$dir/arm.out"
  pidfile="$state/.watch.lock/pid"
  allowfile="$state/allow-exit"
  mkdir -p "$armdir"
  cp "$ROOT/bin/fm-watch-arm.sh" "$armdir/fm-watch-arm.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$armdir/fm-wake-lib.sh"
  cat > "$armdir/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$$" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$SCRIPT_DIR/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
fm_pid_identity "$$" > "$STATE/.watch.lock/pid-identity"
touch "$STATE/.last-watcher-beat"
while [ ! -e "${FM_ALLOW_EXIT_FILE:?}" ]; do
  touch "$STATE/.last-watcher-beat"
  sleep 0.05
done
rm -rf "$STATE/.watch.lock" 2>/dev/null || true
rm -f "$STATE/.last-watcher-beat" 2>/dev/null || true
exit 0
SH
  chmod +x "$armdir/fm-watch.sh" "$armdir/fm-watch-arm.sh" "$armdir/fm-wake-lib.sh"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_ARM_CONFIRM_TIMEOUT=1 FM_WATCH_DELIVERY_MAX_BYTES=1024 FM_WATCH_DELIVERY_KEEP_LINES=4 \
    FM_ALLOW_EXIT_FILE="$allowfile" "$armdir/fm-watch-arm.sh" > "$armout" &
  ARM_PID=$!
  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$pidfile" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$pidfile" ] || fail "attached arm did not spawn a watcher child"
  i=0
  while [ "$i" -lt 100 ]; do
    watch_pid=$(cat "$pidfile" 2>/dev/null || true)
    [ -n "$watch_pid" ] || { sleep 0.05; i=$((i + 1)); continue; }
    grep -qF "watcher: started pid=$watch_pid (beacon fresh)" "$armout" 2>/dev/null && break
    sleep 0.05
    i=$((i + 1))
  done
  watch_pid=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$watch_pid" ] || fail "could not read the watcher child pid"
  watch_identity=$(
    FM_STATE_OVERRIDE="$state" bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      fm_pid_identity "$2"
    ' _ "$armdir/fm-wake-lib.sh" "$watch_pid"
  )
  [ -n "$watch_identity" ] || fail "could not resolve the watcher child identity"
  grep -qF "watcher: started pid=$watch_pid (beacon fresh)" "$armout" \
    || fail "attached arm did not confirm the live watcher: $(cat "$armout")"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    FM_WATCH_DELIVERY_PID="$2" FM_WATCH_DELIVERY_IDENTITY="$3" watch_delivery_publish "owner-delivered reason"
    i=0
    while [ "$i" -lt 24 ]; do
      pid=$((100000 + i))
      FM_WATCH_DELIVERY_PID="$pid" FM_WATCH_DELIVERY_IDENTITY="noise-$i" watch_delivery_publish "noise reason $i xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
      i=$((i + 1))
    done
  ' _ "$ROOT/bin/fm-push-transition-lib.sh" "$watch_pid" "$watch_identity"
  awk -F '\t' -v pid="$watch_pid" -v identity="$watch_identity" '$1 == pid && $2 == identity { found = 1 } END { exit found ? 0 : 1 }' \
    "$state/.watch-deliveries.log" \
    || fail "the owner-delivered record vanished before the arm read it"
  printf 'go\n' > "$allowfile"
  wait_for_exit "$ARM_PID" 120
  status=$?
  grep -qF 'watcher: cycle closed actionably (reason delivered by its owner arm)' "$armout" \
    || fail "attached arm did not report the owner-delivered close after the delivery churn: $(cat "$armout")"
  expect_code 0 "$status" "an attached arm must still close successfully after delivery churn"
  if [ -f "$state/.watch-deliveries.log" ] && awk -F '\t' -v pid="$watch_pid" -v identity="$watch_identity" '$1 == pid && $2 == identity { found = 1 } END { exit found ? 0 : 1 }' "$state/.watch-deliveries.log"; then
    fail "the consumed owner-delivered record remained after close"
  fi
  pass "watch-arm: the owner-delivered record survives churn until the arm consumes it"
}

test_attached_arm_reports_the_delivered_wake
test_attached_arm_reports_the_delivered_wake_after_drain
test_attached_arm_still_fails_on_a_wake_it_did_not_deliver
test_attached_arm_keeps_the_owner_delivery_until_it_is_read
