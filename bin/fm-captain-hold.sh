#!/usr/bin/env bash
# fm-captain-hold.sh - deterministic mechanics for tasks held for the captain.
#
# The semantic policy is owned once by
# .agents/skills/captain-hold-lifecycle/SKILL.md. This script never reads
# report, visual-review, chat, or terminal prose to guess whether the captain
# owes an answer. The invoking agent decides what is genuinely waiting on the
# captain; this script supplies guarded creation, a durable record of what the
# captain actually said, the investigation completion gate, and the one
# keyed-answer intake every channel feeds.
#
# There is no separate decision type. A captain call is an ordinary backlog
# task held for the captain (`tasks-axi hold <id> --kind captain`), and its
# identity is simply the task id. Older installs created derived
# `<origin>-decision-<key>` identities through bin/fm-decision-hold.sh; those
# rows are already plain task ids, so they keep working here unchanged, and
# the legacy inputs noted below resolve them without a migration.
# All backlog mutations run in the active FM_HOME, which keeps main-home and
# secondmate-home ownership aligned with the work that discovered the call.
#
# Usage:
#   fm-captain-hold.sh hold <task-id> --reason <reason> \
#     [--title <title>] [--repo <repo>] [--origin <origin-id>] [--until YYYY-MM-DD]
#   fm-captain-hold.sh answer <task-id> --decision-file <path> [--release]
#   fm-captain-hold.sh answers [<legacy-origin> | --any-origin] --source <provenance>   (keyed answers on stdin)
#   fm-captain-hold.sh bind <source-id> [<legacy-origin> | --any-origin]
#   fm-captain-hold.sh unbind <source-id>
#   fm-captain-hold.sh binding <source-id>
#   fm-captain-hold.sh complete <origin-id> (--none | <task-id>...)
#   fm-captain-hold.sh reconcile-requests --source-id <source-id> --source <provenance>   (task ids on stdin)
#   fm-captain-hold.sh verify <origin-id>
#   fm-captain-hold.sh attach <origin-id>
#   fm-captain-hold.sh open <task-id> [--identity] [--distinguish-absent]
#   fm-captain-hold.sh reconcile list
#   fm-captain-hold.sh reconcile close <task-id> --evidence-file <path>
#   fm-captain-hold.sh reconcile note <task-id> --note-file <path>
#   fm-captain-hold.sh diverged
#
# `hold` places an existing task under an active captain hold, or creates the
# task first when no work item exists to hold (--title required to create; the
# optional --origin records provenance in the new task's body and supplies the
# default repo from that origin's metadata). Prefer holding the work item the
# question gates over minting a new row. Repeating `hold` with the same id is
# idempotent; a task already closed is refused rather than reopened. `--until`
# records the captain's own deferral date through `tasks-axi hold --until`, so
# a "revisit later" answer is stored as a date instead of a live card.
#
# `answer` records the captain's exact words and closes the call in the same
# act. It requires a non-empty captain decision file of at most 8192 bytes,
# writes a resolution block at the top of the task body (the previous body is
# preserved below the block and archived through tasks-axi --archive-body),
# then closes the task with `tasks-axi done` - or, with `--release`, lifts the
# hold with `tasks-axi unhold` so a captain-gated WORK item resumes instead of
# closing. An exact retry is idempotent only when its requested close mode
# matches the newest record; a changed decision or a mode mismatch is rejected.
# A re-held task may record a new answer on top. On a task already closed outside this script,
# `answer` records the missing resolution block (the old `repair` path) only
# when the task still carries the captain-hold provenance tasks-axi preserves
# through a close, so an ordinary finished task cannot be dressed up as an
# answered captain call. A hold that expired by date (`--until` in the past) is
# still answerable: the surviving hold annotations, not tasks-axi's live
# `held:` bit, prove the captain owned it.
#
# ONE KEYED-ANSWER INTAKE, FED BY EVERY CHANNEL.
# "A keyed answer closes its matching captain-held task" is a single
# capability, owned here and nowhere else. `answers` reads
# `<task-id>\t<answer>\t<label>[\t<mode>]` lines on stdin and closes each named
# task through the very same `answer` path above, so every guard applies
# identically no matter which channel the answer arrived on. The key IS the
# task id - no identity arithmetic. The optional fourth field selects the close:
# empty or `done` completes the task, `release` lifts the hold so held work
# resumes; anything else is skipped. A key that names no task, a task that is
# not held for the captain, or a task already closed is reported as `skipped:`
# and feeds nothing. A replayed delivery whose answer digest and requested
# close mode both match the newest record is reported `closed:` and is a no-op;
# a mode mismatch is skipped. The command exits nonzero when any key was
# skipped. `--source` is provenance text recorded in the
# durable decision, never a behavior switch: this command has no per-channel
# branch and no knowledge of chat, review decks, or any transport.
# Legacy input: an optional positional origin (or a stored concrete-origin
# binding) makes a key that names no task fall back to the old
# `<origin>-decision-<key>` identity, so an in-flight pre-collapse channel
# keeps closing its rows; `--any-origin` and the stored `(any)` marker mean
# what an absent origin means and are accepted for the same reason.
#
# A channel's ONLY job is to turn whatever it received into those keyed lines
# and pipe them here. It must never map keys to tasks, build decision records,
# choose a close mode beyond what its card declared, or close anything itself.
#
# `bind`, `unbind`, and `binding` record that a captured-answer SOURCE feeds
# this intake, for any channel whose answers arrive detached from their origin
# (a process-event source id, for example). The binding is a private record
# under `state/decision-bindings/`; a source with no binding feeds nothing, so
# this whole path is opt-in per source and an unbound source behaves as if it
# did not exist. `bind` deliberately does not require the source to exist yet,
# so a channel can be bound BEFORE it is armed. The optional second argument
# exists only for legacy pre-collapse records and callers: a concrete origin is
# stored verbatim and used as the composition fallback above, and
# `--any-origin` stores the same `(any)` marker a plain `bind <source-id>`
# stores. `binding` prints the stored value verbatim and `answers` accepts it,
# so the process-event runner's feed seam is unchanged.
#
# `complete` is the shared investigation and visual-review completion gate.
# It attests, in the origin task's metadata, the reviewed inventory of
# captain-held tasks that carry the origin's unresolved captain calls.
# `--none` is an explicit semantic attestation that the just-reviewed surface
# has no unresolved captain call, and is refused while the origin still has an
# open keyed status decision. With a non-empty inventory, every listed task is
# verified durable (actively captain-held, or closed with a recorded answer),
# the inventory is unioned idempotently into the metadata, and every still-open
# keyed status decision is transferred to its durable owner with a
# `captain-held [key=...]` status close naming the inventory. Later review
# passes may add ids. A post-teardown visual review can complete against the
# surviving report and tasks without recreating task state.
# `verify` is read-only and is called by scout teardown, so teardown cannot
# erase a source before this gate has succeeded: every recorded inventory
# entry must still be durable and no keyed status decision may be open.
# Metadata compatibility: the attestation keeps the historical
# `decisions_reviewed=1` and `decision_keys=` keys, and an inventory entry that
# names no existing task resolves through the legacy `<origin>-decision-<entry>`
# identity, so pre-collapse metadata written by fm-decision-hold.sh verifies
# unchanged. An entry that exists as a task id is always that task.
#
# `attach` gives an already-collected report a durable origin identity when no
# ordinary task metadata was ever created for it - the routed-research case
# where a persistent secondmate delivers a self-contained
# `data/<origin-id>/report.md` straight from its own session instead of a
# fm-spawn.sh crewmate. Without an origin record, `complete` cannot persist its
# attestation and `verify` refuses outright, so the investigation stays falsely
# incomplete even though the report and a `--none` inventory both already
# exist. `attach` closes exactly that gap and nothing else: it requires the
# report at exactly that canonical path (a regular, non-symlinked, non-empty
# file, with every intermediate directory also non-symlinked) and requires
# `<origin-id>` to already name an authoritative task in this home's own backlog
# (`tasks-axi show`), so attach can bind an existing report to existing authority
# but never invent either. It refuses when ordinary `state/<origin-id>.meta`
# exists, so a spawn's live scout, ship, or secondmate record is untouched, and
# a fresh spawn likewise refuses an attached research origin. An exact retry -
# same origin, byte-identical report - is an idempotent no-op; a
# different report under the same origin is refused as a conflicting
# reassociation, and every check runs before the one atomic publish, so a
# rejected input never partially writes the record. The attached record lives
# at `state/captain-hold-origins/<origin-id>.meta`, outside the top-level
# `state/*.meta` live-worker inventory, and carries only `kind=research`, the
# attached report's path and digest, and the origin task's own `repo:` as
# `project=` (so a later `hold --origin` on this origin still defaults its repo
# correctly). It carries no `window`, `worktree`, or `endpoint_task_id` and is
# never enumerated as a live agent. `attach` establishes only the durable
# research origin the completion gate needs; it never claims implementation,
# validation, or project delivery; only `complete` and `verify` establish or
# check the captain-call inventory on top of it. `complete` and `attach`
# serialize through the same per-origin metadata lock (`fm_meta_lock_path`), so
# a concurrent attach and completion attempt on one origin cannot leave a
# half-published record. If `complete` wins that lock before origin metadata is
# published, it refuses without mutation and tells the caller to retry after
# `attach`; if `attach` wins, the waiting completion records its attestation.
#
# `diverged` is the read-only guard over the seam between the two records of
# one captain call. See "record divergence" beside command_diverged below.
#
# Resolution records: the block written into the body names this script, the
# decision digest, and a `Resolution mode:` of answered, released, or repaired.
# Records written by the retired fm-decision-hold.sh (routed, declined,
# answered, repaired) are recognized everywhere a record is read, so nothing
# already closed needs rewriting.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

PARENT_HOLD_PUBLISHED=0
publish_parent_hold() {  # <task-id> <occurrence> <verb> <note>
  local id=$1 occurrence=$2 verb=$3 note=$4 rc=0
  PARENT_HOLD_PUBLISHED=0
  fm_parent_channel_report "$FM_HOME" "$STATE" \
    "$verb [key=captain-hold-$id-$occurrence]: captain hold $id: $(fm_parent_channel_clean_note "$note")" || rc=$?
  case "$rc" in
    0|1) PARENT_HOLD_PUBLISHED=1 ;;
    *) printf 'actionable: task %s is held for the captain in this home but that did not reach the parent channel (rc=%s)\n' "$id" "$rc" >&2 ;;
  esac
}

CAPTAIN_META_LOCK=
CAPTAIN_META_LOCK_HELD=0
CAPTAIN_CONTROL_LOCK=
CAPTAIN_CONTROL_LOCK_HELD=0
captain_hold_cleanup() {
  if [ "$CAPTAIN_META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_META_LOCK" || true
    CAPTAIN_META_LOCK_HELD=0
  fi
  if [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CAPTAIN_CONTROL_LOCK" || true
    CAPTAIN_CONTROL_LOCK_HELD=0
  fi
}
trap captain_hold_cleanup EXIT


usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-captain-hold: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) fail "$label must be a non-empty privacy-safe slug: $value" ;;
  esac
}

validate_one_line() {  # <label> <value>
  local label=$1 value=$2
  [ -n "$value" ] || fail "$label must not be empty"
  case "$value" in
    *$'\n'*|*$'\r'*) fail "$label must be one line" ;;
  esac
}

acquire_task_control_lock() {  # <task-id>
  CAPTAIN_CONTROL_LOCK="$STATE/.control-$1.lock"
  fm_lock_acquire_wait "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=1
}

release_task_control_lock() {
  [ "$CAPTAIN_CONTROL_LOCK_HELD" = 1 ] || return 0
  fm_lock_release "$CAPTAIN_CONTROL_LOCK"
  CAPTAIN_CONTROL_LOCK_HELD=0
  CAPTAIN_CONTROL_LOCK=
}

sha256_text() {  # <text>
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    fail "shasum or sha256sum is required"
  fi
}

pin_report_for_attach() {  # <origin-id>
  perl -MFcntl=:DEFAULT,:mode,F_SETFD -MFile::Spec -e '
    use strict;
    use warnings;

    my ($script, $origin, $data) = @ARGV;
    $data = File::Spec->rel2abs($data);
    my $nofollow = eval { Fcntl::O_NOFOLLOW() };
    my $directory = eval { Fcntl::O_DIRECTORY() };
    exit 1 if !defined($nofollow) || !defined($directory);

    sub identity {
      my ($fh, $kind) = @_;
      my @st = stat($fh);
      return if !@st;
      return if $kind eq "dir" && !S_ISDIR($st[2]);
      return if $kind eq "file" && (!S_ISREG($st[2]) || !$st[7]);
      return join(":", @st[0, 1, 2, 3, 7, 9, 10]);
    }

    sysopen(my $data_fh, $data, O_RDONLY | $nofollow | $directory) or exit 1;
    chdir($data) or exit 1;
    my $data_identity = identity($data_fh, "dir");
    my @cwd = stat(".");
    exit 1 if !defined($data_identity) || !@cwd
      || join(":", @cwd[0, 1, 2, 3, 7, 9, 10]) ne $data_identity;

    sysopen(my $dir_fh, $origin, O_RDONLY | $nofollow | $directory) or exit 1;
    chdir($origin) or exit 1;
    my $dir_identity = identity($dir_fh, "dir");
    @cwd = stat(".");
    exit 1 if !defined($dir_identity) || !@cwd
      || join(":", @cwd[0, 1, 2, 3, 7, 9, 10]) ne $dir_identity;

    sysopen(my $report_fh, "report.md", O_RDONLY | $nofollow) or exit 1;
    exit 1 if !defined identity($report_fh, "file");
    for my $fh ($data_fh, $dir_fh, $report_fh) {
      fcntl($fh, F_SETFD, 0) or exit 1;
    }
    $ENV{FM_ATTACH_PINNED_DATA_FD} = fileno($data_fh);
    $ENV{FM_ATTACH_PINNED_DIR_FD} = fileno($dir_fh);
    $ENV{FM_ATTACH_PINNED_REPORT_FD} = fileno($report_fh);
    exec {$script} $script, "__attach-pinned", $origin;
    exit 1;
  ' "$SCRIPT_DIR/fm-captain-hold.sh" "$1" "$DATA"
}

pinned_report_guard() {  # <mode> <origin-id> [expected-digest] [repo]
  local mode=$1 origin=$2 expected=${3:-} repo=${4:-}
  case "${FM_ATTACH_PINNED_DATA_FD:-}:${FM_ATTACH_PINNED_DIR_FD:-}:${FM_ATTACH_PINNED_REPORT_FD:-}" in
    *[!0-9:]*) return 1 ;;
    :*|*::*|*:) return 1 ;;
  esac
  perl -MFcntl=:DEFAULT,:mode -MDigest::SHA -MFile::Spec -MFile::Temp=tempfile -e '
    use strict;
    use warnings;

    my ($mode, $origin, $expected, $repo, $data, $state, $data_fd, $dir_fd, $report_fd) = @ARGV;
    $data = File::Spec->rel2abs($data);
    $state = File::Spec->rel2abs($state);
    my $report_dir = "$data/$origin";
    my $report = "$report_dir/report.md";
    my $research_state = "$state/captain-hold-origins";

    sub fd_identity {
      my ($fh, $kind) = @_;
      my @st = stat($fh);
      return if !@st;
      return if $kind eq "dir" && !S_ISDIR($st[2]);
      return if $kind eq "file" && (!S_ISREG($st[2]) || !$st[7]);
      return join(":", @st[0, 1, 2]) if $kind eq "dir";
      return join(":", @st[0, 1, 2, 3, 7, 9, 10]);
    }

    sub path_identity {
      my ($path, $kind) = @_;
      my @st = lstat($path);
      return if !@st || S_ISLNK($st[2]);
      return if $kind eq "dir" && !S_ISDIR($st[2]);
      return if $kind eq "file" && (!S_ISREG($st[2]) || !$st[7]);
      return join(":", @st[0, 1, 2]) if $kind eq "dir";
      return join(":", @st[0, 1, 2, 3, 7, 9, 10]);
    }

    sub fd_inode_identity {
      my ($fh) = @_;
      my @st = stat($fh);
      return if !@st || !S_ISREG($st[2]);
      return join(":", @st[0, 1]);
    }

    sub path_inode_identity {
      my ($path) = @_;
      my @st = lstat($path);
      return if !@st || S_ISLNK($st[2]) || !S_ISREG($st[2]);
      return join(":", @st[0, 1]);
    }

    open(my $data_fh, "<&$data_fd") or exit 1;
    open(my $dir_fh, "<&$dir_fd") or exit 1;
    open(my $report_fh, "<&$report_fd") or exit 1;
    binmode($report_fh);
    my $data_identity = fd_identity($data_fh, "dir");
    my $dir_identity = fd_identity($dir_fh, "dir");
    my $report_identity = fd_identity($report_fh, "file");
    exit 1 if !defined($data_identity) || !defined($dir_identity) || !defined($report_identity);
    exit 1 if !defined(path_identity($data, "dir")) || path_identity($data, "dir") ne $data_identity;
    exit 1 if !defined(path_identity($report_dir, "dir")) || path_identity($report_dir, "dir") ne $dir_identity;
    exit 1 if !defined(path_identity($report, "file")) || path_identity($report, "file") ne $report_identity;
    seek($report_fh, 0, 0) or exit 1;
    my $digest = Digest::SHA->new(256)->addfile($report_fh)->hexdigest;
    exit 1 if !defined(fd_identity($report_fh, "file")) || fd_identity($report_fh, "file") ne $report_identity;
    exit 1 if !defined(path_identity($data, "dir")) || path_identity($data, "dir") ne $data_identity;
    exit 1 if !defined(path_identity($report_dir, "dir")) || path_identity($report_dir, "dir") ne $dir_identity;
    exit 1 if !defined(path_identity($report, "file")) || path_identity($report, "file") ne $report_identity;
    exit 1 if length($expected) && $digest ne $expected;
    if ($mode eq "publish") {
      my $nofollow = eval { Fcntl::O_NOFOLLOW() };
      my $directory = eval { Fcntl::O_DIRECTORY() };
      exit 1 if !defined($nofollow) || !defined($directory);
      sysopen(my $state_fh, $state, O_RDONLY | $nofollow | $directory) or exit 1;
      my $state_identity = fd_identity($state_fh, "dir");
      exit 1 if !defined($state_identity) || !defined(path_identity($state, "dir"))
        || path_identity($state, "dir") ne $state_identity;
      chdir($state_fh) or exit 1;
      my @namespace = lstat("captain-hold-origins");
      if (!@namespace) {
        mkdir("captain-hold-origins", 0700) or do {
          @namespace = lstat("captain-hold-origins");
          exit 1 if !@namespace;
        };
      }
      sysopen(my $research_fh, "captain-hold-origins", O_RDONLY | $nofollow | $directory) or exit 1;
      my $research_identity = fd_identity($research_fh, "dir");
      exit 1 if !defined($research_identity) || !defined(path_identity($research_state, "dir"))
        || path_identity($research_state, "dir") ne $research_identity;
      chdir($research_fh) or exit 1;
      my @published = lstat("$origin.meta");
      exit 1 if @published;
      my ($tmp_fh, $tmp_name) = tempfile(".$origin.meta.attach.XXXXXX", DIR => ".", UNLINK => 1);
      binmode($tmp_fh);
      print {$tmp_fh} "kind=research\nreport=data/$origin/report.md\nreport_digest=$digest\n" or exit 1;
      print {$tmp_fh} "project=$repo\n" or exit 1 if length($repo);
      my $staged_inode = fd_inode_identity($tmp_fh);
      exit 1 if !defined($staged_inode);
      close($tmp_fh) or exit 1;
      exit 1 if !defined(fd_identity($state_fh, "dir")) || fd_identity($state_fh, "dir") ne $state_identity;
      exit 1 if !defined(fd_identity($research_fh, "dir")) || fd_identity($research_fh, "dir") ne $research_identity;
      exit 1 if !defined(path_identity($state, "dir")) || path_identity($state, "dir") ne $state_identity;
      exit 1 if !defined(path_identity($research_state, "dir"))
        || path_identity($research_state, "dir") ne $research_identity;
      exit 1 if !defined(path_identity($data, "dir")) || path_identity($data, "dir") ne $data_identity;
      exit 1 if !defined(path_identity($report_dir, "dir")) || path_identity($report_dir, "dir") ne $dir_identity;
      exit 1 if !defined(path_identity($report, "file")) || path_identity($report, "file") ne $report_identity;
      rename($tmp_name, "$origin.meta") or exit 1;
      my $published_here = path_inode_identity("$origin.meta");
      my $published_canonical = path_inode_identity("$research_state/$origin.meta");
      my $published_safely = defined($published_here) && $published_here eq $staged_inode
        && defined($published_canonical) && $published_canonical eq $staged_inode
        && defined(fd_identity($state_fh, "dir")) && fd_identity($state_fh, "dir") eq $state_identity
        && defined(fd_identity($research_fh, "dir")) && fd_identity($research_fh, "dir") eq $research_identity
        && defined(path_identity($state, "dir")) && path_identity($state, "dir") eq $state_identity
        && defined(path_identity($research_state, "dir"))
        && path_identity($research_state, "dir") eq $research_identity
        && defined(path_identity($data, "dir")) && path_identity($data, "dir") eq $data_identity
        && defined(path_identity($report_dir, "dir")) && path_identity($report_dir, "dir") eq $dir_identity
        && defined(path_identity($report, "file")) && path_identity($report, "file") eq $report_identity;
      if (!$published_safely) {
        unlink("$origin.meta") if defined($published_here) && $published_here eq $staged_inode;
        exit 1;
      }
    } elsif ($mode ne "digest" && $mode ne "check") {
      exit 1;
    }
    print "$digest\n";
  ' "$mode" "$origin" "$expected" "$repo" "$DATA" "$STATE" \
    "$FM_ATTACH_PINNED_DATA_FD" "$FM_ATTACH_PINNED_DIR_FD" "$FM_ATTACH_PINNED_REPORT_FD"
}

# The legacy derived identity older installs minted for a captain call.
# Kept only to resolve pre-collapse rows, metadata entries, and channel keys.
legacy_hold_id() {  # <origin-id> <key>
  printf '%s-decision-%s' "$1" "$2"
}

# The legacy any-origin binding marker. Slug validation rejects parentheses, so
# no real origin id or task id can collide with it.
BINDING_ANY='(any)'

DECISION_TEXT=''
DECISION_DIGEST=''

load_decision() {  # <path>; sets DECISION_TEXT and DECISION_DIGEST
  local path=$1 decision
  [ -n "$path" ] || fail "--decision-file is required"
  [ -f "$path" ] || fail "decision file does not exist: $path"
  decision=$(cat "$path")
  [ -n "$decision" ] || fail "decision file must not be empty"
  [ "$(printf '%s' "$decision" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "decision file exceeds 8192 bytes"
  DECISION_TEXT=$decision
  DECISION_DIGEST=$(sha256_text "$decision")
}

tasks_axi() {
  local data file root backend
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  root=$(fm_backlog_root "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || fail "$FM_BACKLOG_TRANSITION_ERROR"
    (cd "$root" && tasks-axi "$@" --file "$file")
  else
    (cd "$root" && tasks-axi "$@")
  fi
}

require_tasks_axi() {
  fm_tasks_axi_compatible || fail "compatible tasks-axi is required"
  tasks-axi hold --help 2>&1 | grep -F -- '--kind captain' >/dev/null \
    || fail "tasks-axi does not expose the captain-hold contract"
}

# Read one row into TASK_SHOW_OUTPUT; a non-zero return means the row is
# absent. A read that could not finish inside its bound is NOT absence, and
# every caller below would otherwise spend it as one - minting a duplicate task,
# skipping a keyed answer, or reporting a task that exists as missing. So the
# bound's own status stops the command instead, loudly and by name, and it
# leaves 124 intact rather than collapsing to fail's 1 so a caller running this
# inside a command substitution can still tell a wedged backend from a
# genuinely unknown id.
TASK_SHOW_OUTPUT=
task_show() {  # <id>; sets TASK_SHOW_OUTPUT
  local data status=0 reason
  data=$(fm_backlog_data_absolute "$DATA") || fail "data directory cannot be resolved: $DATA"
  TASK_SHOW_OUTPUT=$(fm_backlog_row_show "$data" "$1" --full 2>/dev/null) || status=$?
  if [ "$status" -eq 124 ]; then
    reason=${TASK_SHOW_OUTPUT%%$'\n'*}
    printf 'fm-captain-hold: %s\n' \
      "${reason:-tasks-axi show $1 exceeded its backlog read bound}" >&2
    exit 124
  fi
  return "$status"
}

# Read one row into `show`, failing with <absence-message> only when the read
# genuinely failed; a read-bound hit (124) stops the command by name instead.
# task_show must be called in THIS shell, not inside a command substitution:
# it carries the row in TASK_SHOW_OUTPUT, which a subshell cannot hand back.
task_show_or_fail() {  # <id> <absence-message>; sets show
  task_show "$1" || {
    [ "$?" -ne 124 ] || fail "the backlog backend exceeded its read bound reading $1"
    fail "$2"
  }
  show=$TASK_SHOW_OUTPUT
}

show_field() {  # <show-output> <field>
  local output=$1 field=$2
  printf '%s\n' "$output" | sed -n "s/^  $field: //p" | head -1
}

decode_shown_value() {  # <shown-field>
  local value=$1
  case "$value" in
    \"*\")
      printf '%s' "$value" | perl -MJSON::PP -e '
        local $/;
        my $value = decode_json(<STDIN>);
        binmode STDOUT, ":raw";
        utf8::encode($value) if utf8::is_utf8($value);
        print $value;
      '
      ;;
    *) printf '%s' "$value" ;;
  esac
}

# Decode show-encoded scalar fields and normalize the empty marker.
show_field_value() {  # <show-output> <field>
  local value
  value=$(decode_shown_value "$(show_field "$1" "$2")")
  [ "$value" != '-' ] || value=''
  printf '%s' "$value"
}

origin_exists_here() {  # <origin-id>
  load_origin_meta "$1" && return 0
  [ -f "$DATA/$1/report.md" ] && return 0
  task_show "$1" >/dev/null 2>&1
}

list_has_key() {  # <comma-list> <key>
  case ",$1," in
    *",$2,"*) return 0 ;;
    *) return 1 ;;
  esac
}

sorted_key_union() {  # <comma-list> <newline-or-space-separated-new-keys>
  local existing=$1 new=$2
  {
    printf '%s\n' "$existing" | tr ',' '\n'
    printf '%s\n' "$new" | tr ' ' '\n'
  } | sed '/^$/d' | LC_ALL=C sort -u | paste -sd, -
}

meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_text_value() {  # <metadata-text> <key>
  printf '%s\n' "$1" | grep "^$2=" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

origin_open_decisions() {  # <origin-id>
  local origin=$1 status_file="$STATE/$1.status" open kind last verb
  open=$(status_open_decisions "$status_file")
  [ -n "$open" ] || return 0
  load_origin_meta "$origin" || { printf '%s' "$open"; return 0; }
  kind=$(meta_text_value "$ORIGIN_META_TEXT" kind)
  [ -n "$kind" ] || kind=ship
  if [ "$kind" != secondmate ] && [ "$kind" != research ]; then
    last=$(last_status_line "$status_file")
    verb=$(status_line_verb "$last")
    case "$verb" in
      done|failed) return 0 ;;
    esac
  fi
  printf '%s' "$open"
}

# A resolution record written by this script or by the retired
# fm-decision-hold.sh. Both carry the same leader-then-captain-decision shape.
body_has_resolution_record() {  # <task-body>
  case "$1" in
    *"Resolution recorded by fm-captain-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-decision-hold."*"Captain decision:"*) return 0 ;;
    *"Resolution recorded by fm-captain-hold."*"Reconciliation evidence:"*) return 0 ;;
  esac
  return 1
}

# The recorded decision digest of either record format, from the show-escaped
# body (multi-line bodies print as one quoted line with \n escapes). Records
# are prepended, so the first match is the newest record.

# The recorded decision digest of either record format, from the show-escaped
# body (multi-line bodies print as one quoted line with \n escapes). Records
# are prepended, so the first match is the newest record.
resolution_record_count() {  # <task-body>
  local body
  body=$(decode_shown_value "$1") || return 1
  printf '%s\n' "$body" \
    | grep -Ec '^Resolution recorded by fm-(captain|decision)-hold\.$' || true
}

body_hold_set_timestamp() {  # <decoded-task-body>
  printf '%s\n' "$1" \
    | sed -n \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\)$/\1/p' \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | head -1
}


# The newest record's `Resolution mode:` value; empty for a record predating it.

recorded_decision_digest() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Decision digest: "*) rest=${rest#*"Decision digest: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

# The newest record's `Resolution mode:` value; empty for a record predating it.
recorded_resolution_mode() {  # <task-body>
  local rest=$1
  case "$rest" in
    *"Resolution mode: "*) rest=${rest#*"Resolution mode: "} ;;
    *) return 1 ;;
  esac
  rest=${rest%%\\n*}
  rest=${rest%%$'\n'*}
  printf '%s' "$rest"
}

closed_answer_replay_mode_compatible() {  # <mode> <task-body>
  case "$1" in
    answered|repaired|routed) return 0 ;;
  esac
  return 1
}

# The record's label is what keeps an evidence-backed reconciliation from
# reading as the captain's own words. `reconciled` closes a call that went moot
# and carries verified evidence; every other mode carries what the captain said.
resolution_block() {  # <mode>
  local label='Captain decision:'
  [ "$1" != reconciled ] || label='Reconciliation evidence:'
  printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: %s\n\n%s\n%s\n' \
    "$DECISION_DIGEST" "$1" "$label" "$DECISION_TEXT"
}

# Durable state of one captain call: an active captain hold (annotations
# surviving even when a date gate has expired) or a recorded captain answer.
verify_hold_durable() {  # <task-id> [resolution-kind]
  local id=${1%% *} show state hold_kind body
  show=$(task_show "$id") || fail "captain-held task $id is absent from $FM_HOME/data/backlog.md"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if body_has_resolution_record "$body"; then
    return 0
  fi
  if [ "$state" != "done" ] && [ "$hold_kind" = captain ]; then
    return 0
  fi
  fail "captain-held task $id is neither held for the captain nor closed with a recorded captain answer"
}

# --- migrated legacy-id resolution on the Beads backend ---------------------
#
# A home that moved its backlog from markdown to Beads no longer carries the
# legacy hold ids a scout report attested: the migration rehomed every held
# row under a prefixed fm- id and recorded its markdown identity in the row's
# notes as "migrated from data/backlog.md id <legacy id>", alone or followed by
# " on <date>" (fm-hold-migration wrote the dated form on 2026-09-04). When an
# attested legacy id resolves to no task, the beads backend accepts the row the
# migration produced, found by scanning the configured graph's notes for either
# form of that marker line, and only when no row carries the marker by
# prepending the configured prefix to the legacy id - a name-only guess, so it
# is accepted solely for a row still held for the captain and only when it is
# the single such row. A markdown home keeps its legacy rows verbatim, so its
# exact-id resolution is unchanged.

CAPTAIN_MIGRATION_SCAN_LOADED=0
CAPTAIN_MIGRATION_SCAN_JSON=
NL_SEP=$'\n'

# Section-aware [beads] extraction from a .tasks.toml: only keys inside the
# [beads] section, comments stripped. Prints "<key> <value>" lines.
captain_beads_toml_entries() {  # <toml-file>
  [ -f "$1" ] || return 0
  LC_ALL=C awk '
    function trim(v) { sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); return v }
    BEGIN { inbeads = 0 }
    {
      line = $0
      sub(/[[:space:]]*#.*/, "", line)
      line = trim(line)
      if (line ~ /^\[[^]]+\]$/) { inbeads = (line == "[beads]"); next }
      if (!inbeads) next
      if (line ~ /^(prefix|path|binary)[[:space:]]*=/) {
        key = line
        sub(/[[:space:]]*=.*/, "", key)
        sub(/^[^=]*=[[:space:]]*/, "", line)
        gsub(/^"|"$/, "", line); gsub(/^'\''|'\''$/, "", line)
        printf "%s %s\n", key, line
      }
    }
  ' "$1"
}

captain_beads_setting() {  # <entries-output> <setting>
  printf '%s\n' "$1" | sed -n "s/^$2 //p" | head -1
}

# Read the configured beads graph's row listing for a migration-note scan.
# The listing is deliberately re-read per unresolvable key: the cache below
# lives and dies with the command-substitution subshell every resolve_entry
# call site runs in, so it cannot persist across keys - bounded by a scout
# report's handful of attested ids. Returns 0 when the listing loads, and 2
# with the reason on stderr when the graph cannot be read.
captain_migration_scan_load() {  # <resolved-data-dir>
  local data=$1 root entries bd_bin bd_path backend
  [ "$CAPTAIN_MIGRATION_SCAN_LOADED" = 1 ] && return 0
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the configured data directory cannot be resolved for a migration scan: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" != beads ]; then
    CAPTAIN_MIGRATION_SCAN_LOADED=1
    return 0
  fi
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  bd_bin=$(captain_beads_setting "$entries" binary)
  bd_path=$(captain_beads_setting "$entries" path)
  bd_bin=${bd_bin:-bd}
  if [ -z "$bd_path" ]; then
    printf 'fm-captain-hold: the beads backend carries no graph path in %s, so a migrated hold cannot be found\n' "$root/.tasks.toml" >&2
    return 2
  fi
  # A relative [beads] path resolves against the backlog root, the same rule
  # every other .tasks.toml path consumer uses, never against the process CWD.
  case "$bd_path" in
    /*) ;;
    *) bd_path="$root/$bd_path" ;;
  esac
  command -v "$bd_bin" >/dev/null 2>&1 || {
    printf 'fm-captain-hold: the beads binary %s is not on PATH, so a migrated hold cannot be found\n' "$bd_bin" >&2
    return 2
  }
  command -v jq >/dev/null 2>&1 || {
    printf 'fm-captain-hold: jq is required to scan the beads graph for a migrated hold\n' >&2
    return 2
  }
  local bd_err
  bd_err=$(mktemp "${TMPDIR:-/tmp}/fm-captain-hold-bd.XXXXXX") || {
    printf 'fm-captain-hold: cannot stage the beads graph read diagnostics\n' >&2
    return 2
  }
  if ! CAPTAIN_MIGRATION_SCAN_JSON=$(BEADS_DIR="$bd_path" "$bd_bin" list --all --json 2>"$bd_err"); then
    printf 'fm-captain-hold: reading the beads graph at %s failed (%s), so a migrated hold cannot be found\n' \
      "$bd_path" "$(sanitize_field "$(head -c 200 "$bd_err" | tr '\n' ' ')")" >&2
    rm -f "$bd_err"
    return 2
  fi
  rm -f "$bd_err"
  CAPTAIN_MIGRATION_SCAN_LOADED=1
  return 0
}

# Resolve one attested legacy id to the migrated row that carries it on the
# beads backend. Prints "<row id> <how>" and returns 0 when exactly one
# migration matches, returns 1 when none does, and returns 2 with the reason on
# stderr when the scan itself cannot run or is ambiguous. The marker note is the
# authoritative evidence and is scanned first; the bare configured prefix is a
# guess, so it only runs when no marker line matches any identity and it accepts
# a row solely when that row is itself still held for the captain.
resolve_migrated_entry() {  # <origin-or-empty> <entry>
  local origin=$1 entry=$2 data root entries prefix derived show backend
  local candidate candidate_matches prefixed matches count prefixed_matches prefixed_count
  data=$(fm_backlog_data_absolute "$DATA") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  root=$(fm_backlog_root "$data") || {
    printf 'fm-captain-hold: the migrated hold of %s cannot be resolved: %s\n' \
      "$entry" "${FM_BACKLOG_TRANSITION_ERROR:-the configured data directory $DATA cannot be resolved}" >&2
    return 2
  }
  backend=$(fm_tasks_axi_backend "$root") || return 2
  [ "$backend" = beads ] || return 1
  # Every identity this entry could have been migrated under: the raw entry,
  # and - for a pre-collapse channel key - the derived legacy identity its
  # origin would have minted, because fm-hold-migration recorded the DERIVED
  # id in each migrated row's marker note.
  CAPTAIN_MIGRATION_IDENTITIES=$entry
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    derived=$(legacy_hold_id "$origin" "$entry")
    if [ "$derived" != "$entry" ]; then
      CAPTAIN_MIGRATION_IDENTITIES="$CAPTAIN_MIGRATION_IDENTITIES $derived"
    fi
  fi
  captain_migration_scan_load "$data" || return 2
  matches=
  if [ -n "$CAPTAIN_MIGRATION_SCAN_JSON" ]; then
    for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
      candidate_matches=$(printf '%s\n' "$CAPTAIN_MIGRATION_SCAN_JSON" | jq -r \
        --arg exact "migrated from data/backlog.md id $candidate" \
        --arg dated "migrated from data/backlog.md id $candidate on " \
        '.[] | select(((.notes // "") | split("\n")) | any(. == $exact or startswith($dated))) | .id' 2>/dev/null) || {
        printf 'fm-captain-hold: the beads graph scan for the migrated hold of %s could not be parsed\n' "$candidate" >&2
        return 2
      }
      matches="${matches}${matches:+$NL_SEP}${candidate_matches}"
    done
    count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
    case "$count" in
      0) : ;;
      1) printf '%s migrated-note' "$(printf '%s\n' "$matches" | sed '/^$/d' | sed -n 1p)"; return 0 ;;
      *)
        printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s rows carry its marker line (identities tried: %s)\n' \
          "$entry" "$count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
        return 2
        ;;
    esac
  fi
  # No marker line anywhere: a mechanical migration keeps the legacy id under
  # the configured prefix, but that name alone is evidence of nothing, so only
  # a row still held for the captain - and only one of them - is accepted.
  entries=$(captain_beads_toml_entries "$root/.tasks.toml")
  prefix=$(captain_beads_setting "$entries" prefix)
  [ -n "$prefix" ] || return 1
  prefixed_matches=
  for candidate in $CAPTAIN_MIGRATION_IDENTITIES; do
    case "$prefix" in
      *-) prefixed="$prefix$candidate" ;;
      *) prefixed="$prefix-$candidate" ;;
    esac
    # Same shell rule as task_show_or_fail: the row is read out of
    # TASK_SHOW_OUTPUT, so the read cannot sit inside a command substitution.
    task_show "$prefixed" 2>/dev/null || {
      [ "$?" -ne 124 ] || return 124
      continue
    }
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
    prefixed_matches="${prefixed_matches}${prefixed_matches:+$NL_SEP}$prefixed"
  done
  prefixed_count=$(printf '%s\n' "$prefixed_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  case "$prefixed_count" in
    0) return 1 ;;
    1) printf '%s migrated-prefix' "$prefixed_matches"; return 0 ;;
  esac
  printf 'fm-captain-hold: the migrated hold of %s is ambiguous: %s captain-held rows carry the configured prefix (identities tried: %s)\n' \
    "$entry" "$prefixed_count" "$(printf '%s' "$CAPTAIN_MIGRATION_IDENTITIES" | tr ' ' ',')" >&2
  return 2
}

# Resolve one inventory entry or channel key to the task that carries it: the
# exact task id when it exists, else the legacy derived identity, else - on the
# beads backend - the migrated row the markdown-to-beads hold migration wrote.
# The shared boundary returns only the resolved task id so every caller uses the
# same identity representation.
resolve_entry() {  # <origin-or-empty> <entry>; prints the resolved id or fails
  local origin=$1 entry=$2 legacy migrated rc
  if task_show "$entry"; then
    printf '%s' "$entry"
    return 0
  fi
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    if task_show "$legacy"; then
      printf '%s' "$legacy"
      return 0
    fi
  fi
  rc=0
  migrated=$(resolve_migrated_entry "$origin" "$entry") || rc=$?
  case "$rc" in
    0) printf '%s' "${migrated%% *}"; return 0 ;;
    2) return 2 ;;
    124) return 124 ;;
  esac
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    legacy=$(legacy_hold_id "$origin" "$entry")
    fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA); the nearest legacy identity $legacy also resolves to nothing"
  fi
  fail "no captain-held task $entry and no migrated hold for it in this home's configured backlog (data directory $DATA)"
}

body_hold_set_timestamp() {  # <decoded-task-body>
  printf '%s\n' "$1" \
    | sed -n \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\)$/\1/p' \
      -e '1s/^Captain hold set: \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/\1/p' \
    | head -1
}

write_hold_set_stamp() {  # <task-id> <shown-body> <timestamp> <preserve-existing-0-or-1>
  local id=$1 body=$2 hold_set=$3 preserve=$4 existing new_body tmp
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  existing=$(body_hold_set_timestamp "$body")
  if [ "$preserve" = 1 ] && [ -n "$existing" ]; then
    return 0
  fi
  if [ -n "$existing" ]; then
    body=${body#"Captain hold set: $existing"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
  fi
  new_body=$(printf 'Captain hold set: %s' "$hold_set")
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-stamp.XXXXXX") \
    || fail "cannot stage the hold-set stamp"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the hold-set stamp for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the hold-set stamp on $id"
  fi
  rm -f -- "$tmp"
}

# Resolve one entry and verify the row it names is durably captain-held. A
# resolution failure that is not the read bound keeps resolve_entry's own
# status - its stderr already named the entry; 124 means the backend never
# answered, which is not the same as an unknown entry and must not be spent
# as absence. On success prints "<id> <how>" so the caller can keep the
# attestation evidence.
verify_entry_durable() {  # <origin-or-empty> <entry>; prints "<id> <how>"
  local origin=$1 entry=$2 resolved resolve_status=0
  resolved=$(resolve_entry "$origin" "$entry") || resolve_status=$?
  if [ "$resolve_status" -ne 0 ]; then
    [ "$resolve_status" -ne 124 ] \
      || fail "the backlog backend exceeded its read bound resolving $entry"
    exit "$resolve_status"
  fi
  printf '%s\n' "$resolved"
  verify_hold_durable "${resolved%% *}"
}

command_hold() {
  local id=${1:-} title='' reason='' repo='' origin='' until='' show state existing_title body='' hold_kind hold_set occurrence
  local existing_hold_kind='' existing_held='' preserve_hold_set=0
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --reason) shift; reason=${1:-} ;;
      --repo) shift; repo=${1:-} ;;
      --origin) shift; origin=${1:-} ;;
      --until) shift; until=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  validate_one_line reason "$reason"
  case "$reason" in *'('*|*')'*) fail "reason must not contain parentheses (tasks-axi hold contract)" ;; esac
  if [ -n "$origin" ]; then
    validate_slug origin-id "$origin"
  fi
  if [ -n "$until" ]; then
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) fail "--until must be a YYYY-MM-DD date: $until" ;;
    esac
  fi
  hold_set=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$hold_set" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "FM_CAPTAIN_HOLD_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  acquire_task_control_lock "$id"
  require_tasks_axi
  if task_show "$id"; then
    show=$TASK_SHOW_OUTPUT
    state=$(show_field "$show" state)
    [ "$state" != "done" ] \
      || fail "task $id is already closed; a new captain call needs its own task"
    existing_hold_kind=$(show_field_value "$show" hold_kind)
    existing_held=$(show_field_value "$show" held)
    if [ "$existing_hold_kind" = captain ] && [ "$existing_held" = yes ]; then
      preserve_hold_set=1
    fi
    if [ -n "$title" ]; then
      existing_title=$(show_field_value "$show" title)
      [ "$existing_title" = "$title" ] || fail "existing task $id has a different title"
    fi
  else
    [ -n "$title" ] || fail "--title is required to create task $id"
    validate_one_line title "$title"
    if [ -z "$repo" ] && [ -n "$origin" ]; then
      if load_origin_meta "$origin"; then
        repo=$(meta_text_value "$ORIGIN_META_TEXT" project)
        repo=${repo%/}
        repo=${repo##*/}
      fi
    fi
    [ -n "$repo" ] || repo=firstmate
    validate_one_line repo "$repo"
    [ -z "$origin" ] || body=$(printf 'Origin: %s' "$origin")
    # tasks-axi add never passes --due. Beads due.required would refuse this
    # create, and captain holds have no due semantics, so waive it for this
    # call only. --kind captain stays metadata; Beads native type is task.
    if [ -n "$body" ]; then
      BD_DUE_REQUIRED=false tasks_axi add "$id" "$title" --kind captain --repo "$repo" --body "$body" >/dev/null \
        || fail "could not create task $id"
    else
      BD_DUE_REQUIRED=false tasks_axi add "$id" "$title" --kind captain --repo "$repo" >/dev/null \
        || fail "could not create task $id"
    fi
  fi
  # Publish the timestamp before the captain-hold annotation. A concurrent
  # snapshot may see the harmless stamp by itself, but can never see a newly
  # held task without the timestamp that defines this hold lifecycle's age.
  task_show_or_fail "$id" "task $id disappeared before recording its hold-set stamp"
  write_hold_set_stamp "$id" "$(show_field "$show" body)" "$hold_set" "$preserve_hold_set"
  task_show_or_fail "$id" "task $id disappeared while recording its hold-set stamp"
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id did not retain its hold-set stamp"
  if [ -n "$until" ]; then
    tasks_axi hold "$id" --reason "$reason" --kind captain --until "$until" >/dev/null \
      || fail "could not hold task $id for the captain"
  else
    tasks_axi hold "$id" --reason "$reason" --kind captain >/dev/null \
      || fail "could not hold task $id for the captain"
  fi
  task_show "$id" || fail "task $id disappeared while holding it"
  show=$TASK_SHOW_OUTPUT
  hold_kind=$(show_field_value "$show" hold_kind)
  [ "$hold_kind" = captain ] || fail "task $id did not retain its captain hold"
  occurrence=$(( $(resolution_record_count "$(show_field "$show" body)") + 1 ))
  [ -n "$(body_hold_set_timestamp "$(show_field_value "$show" body)")" ] \
    || fail "task $id lost its hold-set stamp while being held"
  publish_parent_hold "$id" "$occurrence" needs-decision "$reason"
  printf '%s\n' "$id"
}

# Record a resolution block beneath any leading active hold-set stamp,
# preserving the previous body below it and archiving the pristine original.
# Successful closure removes the stamp to restore resolution-first ordering.
write_resolution_record() {  # <task-id> <mode> <shown-body>
  local id=$1 mode=$2 body=$3 new_body tmp hold_set
  new_body=$(resolution_block "$mode")
  body=$(decode_shown_value "$body") \
    || fail "could not decode the existing body for $id"
  hold_set=$(body_hold_set_timestamp "$body")
  if [ -n "$hold_set" ]; then
    body=${body#"Captain hold set: $hold_set"}
    case "$body" in
      $'\n\n'*) body=${body#$'\n\n'} ;;
      $'\n'*) body=${body#$'\n'} ;;
    esac
    new_body=$(printf 'Captain hold set: %s\n\n%s' "$hold_set" "$new_body")
  fi
  if [ -n "$body" ]; then
    new_body=$(printf '%s\n\n%s' "$new_body" "$body")
  fi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-body.XXXXXX") \
    || fail "cannot stage the resolution record"
  if ! printf '%s\n' "$new_body" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the resolution record for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the captain decision on $id"
  fi
  rm -f -- "$tmp"
}

close_answered() {  # <task-id> <release-0-or-1>
  if [ "$2" = 1 ]; then
    tasks_axi unhold "$1" >/dev/null || fail "could not release captain-held task $1"
  else
    tasks_axi "done" "$1" >/dev/null || fail "could not close answered captain-held task $1"
  fi
}

# --- the one keyed-answer intake, and the source bindings that feed it --------

BINDING_DIR="$STATE/decision-bindings"
BINDING_SCHEMA=fm-decision-binding.v1

validate_source_id() {  # <source-id>
  validate_slug source-id "$1"
  [ "${#1}" -le 64 ] || fail "source-id must be at most 64 characters: $1"
}

binding_path() { printf '%s/%s.origin\n' "$BINDING_DIR" "$1"; }

# The stored binding value, or empty when the source is unbound. An unreadable
# or wrong-schema record is a hard error rather than a silent "unbound":
# feeding nothing is the safe direction only when it is a deliberate choice,
# never when it is a corrupted record.
read_binding() {  # <source-id>
  local path origin schema
  path=$(binding_path "$1")
  [ -e "$path" ] || return 0
  [ -f "$path" ] && [ ! -L "$path" ] || fail "decision binding is unsafe: $path"
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$BINDING_SCHEMA" ] || fail "decision binding has an incompatible schema: $path"
  origin=$(sed -n 's/^origin=//p' "$path" | head -1)
  if [ "$origin" != "$BINDING_ANY" ]; then
    case "$origin" in
      ''|*[!A-Za-z0-9._-]*) fail "decision binding has an invalid origin id: $path" ;;
    esac
  fi
  printf '%s\n' "$origin"
}

command_bind() {
  local source=${1:-} origin=${2:-} dest tmp
  [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  if [ -z "$origin" ] || [ "$origin" = --any-origin ]; then
    origin=$BINDING_ANY
  else
    validate_slug legacy-origin "$origin"
  fi
  (umask 077; mkdir -p "$BINDING_DIR") || fail "cannot create $BINDING_DIR"
  [ -d "$BINDING_DIR" ] && [ ! -L "$BINDING_DIR" ] || fail "decision binding dir is unsafe: $BINDING_DIR"
  dest=$(binding_path "$source")
  tmp=$(umask 077; mktemp "$BINDING_DIR/.origin.XXXXXX") || fail "cannot stage the decision binding"
  if ! { printf 'schema=%s\norigin=%s\n' "$BINDING_SCHEMA" "$origin" > "$tmp" \
    && chmod 0600 "$tmp" && mv -f -- "$tmp" "$dest"; }; then
    rm -f -- "$tmp"
    fail "cannot record the decision binding for $source"
  fi
  printf 'bound: %s -> %s\n' "$source" "$origin"
}

command_unbind() {
  local source=${1:-}
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  rm -f -- "$(binding_path "$source")"
  printf 'unbound: %s\n' "$source"
}

command_binding() {
  local source=${1:-} origin
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_source_id "$source"
  origin=$(read_binding "$source") || exit 1
  [ -n "$origin" ] || return 1
  printf '%s\n' "$origin"
}

# The durable captain decision one keyed answer records. Pure function of its
# inputs, so the same answer delivered twice is idempotent rather than a
# conflicting decision.
keyed_decision_text() {  # <source> <task-id> <answer> <label>
  printf 'Captain answered this call through %s.\n' "$1"
  printf 'Task: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

legacy_keyed_decision_text() {  # <source> <key> <answer> <label>
  printf 'Captain answered this decision through %s.\n' "$1"
  printf 'Decision key: %s\n' "$2"
  printf 'Answer: %s\n' "$3"
  [ -z "$4" ] || printf 'Answer as shown to the captain: %s\n' "$4"
}

sanitize_field() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-512
}

sanitize_reconcile_provenance() {
  printf '%s' "$1" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-1024
}


command_answers() {
  local origin='' source='' row rest key answer label mode id show state hold_kind body digest legacy_digest legacy_key
  local recorded_digest recorded_mode tmp err closed=0 skipped=0 reason release_flag tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source) shift; source=${1:-} ;;
      --any-origin) origin=$BINDING_ANY ;;
      --*) usage >&2; exit 2 ;;
      *)
        [ -z "$origin" ] || { usage >&2; exit 2; }
        origin=$1
        ;;
    esac
    shift
  done
  if [ -n "$origin" ] && [ "$origin" != "$BINDING_ANY" ]; then
    validate_slug legacy-origin "$origin"
  fi
  [ -n "$source" ] || fail "--source provenance is required so the durable decision records where the answer came from"
  source=$(sanitize_field "$source")
  require_tasks_axi
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision.XXXXXX") || fail "cannot stage the captain decision"
  err=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-keyed-decision-err.XXXXXX") \
    || { rm -f -- "$tmp"; fail "cannot stage the captain decision diagnostics"; }
  while IFS= read -r row; do
    key=${row%%"$tab"*}
    rest=''
    case "$row" in *"$tab"*) rest=${row#*"$tab"} ;; esac
    answer=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) rest=${rest#*"$tab"} ;; *) rest='' ;; esac
    label=${rest%%"$tab"*}
    case "$rest" in *"$tab"*) mode=${rest#*"$tab"} ;; *) mode='' ;; esac
    [ -n "${key:-}" ] || continue
    case "$key" in *[!A-Za-z0-9._-]*) continue ;; esac
    [ "${#key}" -le 128 ] || continue
    answer=$(sanitize_field "${answer:-}")
    [ -n "$answer" ] || continue
    label=$(sanitize_field "${label:-}")
    release_flag=''
    case "${mode:-}" in
      ''|done) : ;;
      release) release_flag=--release ;;
      *)
        printf 'skipped: %s (unknown close mode %s)\n' "$key" "$(sanitize_field "$mode")"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    if ! id=$(resolve_entry "$origin" "$key" 2>/dev/null); then
      printf 'skipped: %s (no captain-held task with that id)\n' "$key"
      skipped=$((skipped + 1))
      continue
    fi
    keyed_decision_text "$source" "$id" "$answer" "$label" > "$tmp" \
      || fail "cannot stage the captain decision for $id"
    digest=$(sha256_text "$(cat "$tmp")")
    legacy_digest=''
    if [ "$id" != "$key" ]; then
      legacy_key=$key
    elif { [ -z "$origin" ] || [ "$origin" = "$BINDING_ANY" ]; } \
      && [ "${id#*-decision-}" != "$id" ]; then
      legacy_key=${id#*-decision-}
    else
      legacy_key=''
    fi
    if [ -n "$legacy_key" ]; then
      legacy_digest=$(sha256_text "$(legacy_keyed_decision_text "$source" "$legacy_key" "$answer" "$label")")
    fi
    show=$(task_show "$id") || { printf 'skipped: %s (absent)\n' "$id"; skipped=$((skipped + 1)); continue; }
    state=$(show_field "$show" state)
    hold_kind=$(show_field_value "$show" hold_kind)
    body=$(show_field "$show" body)
    recorded_digest=$(recorded_decision_digest "$body" || true)
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    if body_has_resolution_record "$body" \
      && { [ "$recorded_digest" = "$digest" ] \
        || { case "$body" in *"Resolution recorded by fm-decision-hold."*) true ;; *) false ;; esac \
          && [ -n "$legacy_digest" ] && [ "$recorded_digest" = "$legacy_digest" ]; }; }; then
      if { [ -z "$release_flag" ] && [ "$state" = "done" ] && [ "$recorded_mode" != released ]; } \
        || { [ "$release_flag" = --release ] && [ "$state" != "done" ] \
          && [ "$hold_kind" != captain ] && [ "$recorded_mode" = released ]; }; then
        printf 'closed: %s\n' "$id"
        closed=$((closed + 1))
        continue
      fi
    fi
    if [ "$state" = "done" ]; then
      printf 'skipped: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    if [ "$hold_kind" != captain ]; then
      printf 'skipped: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
      continue
    fi
    # shellcheck disable=SC2086  # release_flag is empty or a single literal flag.
    if "$0" answer "$id" --decision-file "$tmp" $release_flag </dev/null >/dev/null 2>"$err"; then
      printf 'closed: %s\n' "$id"
      closed=$((closed + 1))
    else
      reason=$(tr -d '\n' < "$err" | sed 's/^fm-captain-hold: //')
      printf 'skipped: %s (%s)\n' "$id" "$reason"
      skipped=$((skipped + 1))
    fi
  done
  rm -f -- "$tmp" "$err"
  printf 'answers: closed=%s skipped=%s\n' "$closed" "$skipped"
  [ "$skipped" -eq 0 ]
}

remove_interrupted_answer_stamp() {  # <task-id>
  local id=$1 show body existing tmp
  task_show_or_fail "$id" "task $id disappeared after closing"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the closed body for $id"
  existing=$(body_hold_set_timestamp "$body")
  [ -n "$existing" ] || return 0
  body=${body#"Captain hold set: $existing"}
  case "$body" in
    $'\n\n'*) body=${body#$'\n\n'} ;;
    $'\n'*) body=${body#$'\n'} ;;
  esac
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-normalize.XXXXXX") \
    || fail "cannot stage the closed body for $id"
  if ! printf '%s\n' "$body" > "$tmp" \
    || ! tasks_axi update "$id" --body-file "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    fail "could not restore the resolution record ordering for $id"
  fi
  rm -f -- "$tmp"
}

command_answer() {
  local id=${1:-} decision_file='' release=0 show state hold_kind body outcome recorded_mode occurrence
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --decision-file) shift; decision_file=${1:-} ;;
      --release) release=1 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  load_decision "$decision_file"
  acquire_task_control_lock "$id"
  require_tasks_axi
  task_show "$id" || fail "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  show=$TASK_SHOW_OUTPUT
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  if [ "$release" = 1 ]; then outcome=released; else outcome=answered; fi
  # The occurrence the parent line names: the record about to be written is
  # one past those already in the body, and a retry names the newest one.
  occurrence=$(( $(resolution_record_count "$body") + 1 ))

  if [ "$state" = "done" ]; then
    if body_has_resolution_record "$body"; then
      # An exact compatible retry is an idempotent no-op; drift is rejected.
      [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
        || fail "captain-held task $id records a different captain decision"
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      closed_answer_replay_mode_compatible "$recorded_mode" "$body" \
        || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay"
      [ "$release" = 0 ] \
        || fail "task $id records this answer with mode ${recorded_mode:-unknown}; --release cannot reopen a closed task"
      remove_interrupted_answer_stamp "$id"
      if [ "$recorded_mode" = repaired ]; then
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "answered (repaired)"
      else
        publish_parent_resolution_then_retire "$id" $((occurrence - 1)) answered
      fi
      printf 'answered: %s\n' "$id"
      return 0
    fi
    [ "$release" = 0 ] || fail "task $id is already closed; --release cannot reopen it"
    # Closed outside this script: record the captain's answer retroactively.
    # tasks-axi keeps hold_kind through a close, so it is the surviving proof
    # this really was the captain's item rather than ordinary finished work.
    [ "$hold_kind" = captain ] \
      || fail "task $id was never held for the captain; nothing to record an answer on"
    write_resolution_record "$id" repaired "$body"
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared while recording the answer"
    show=$TASK_SHOW_OUTPUT
    [ "$(show_field "$show" state)" = "done" ] || fail "recording the answer reopened closed task $id"
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "answered (repaired)"
    printf 'repaired: %s\n' "$id"
    return 0
  fi

  if [ "$hold_kind" = captain ]; then
    # Actively the captain's item (a date-expired hold keeps its annotations
    # and stays answerable). A matching record means an interrupted close to
    # finish; a different digest is a NEW answer on a re-held task and gets
    # its own record on top. Either way the close mode is the caller's flag,
    # checked against an interrupted close's recorded mode so a retry cannot
    # silently flip a release into a close.
    if body_has_resolution_record "$body" \
      && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
      recorded_mode=$(recorded_resolution_mode "$body" || true)
      case "$recorded_mode" in
        released) [ "$release" = 1 ] || fail "task $id records this answer as a release; retry with --release" ;;
        answered|routed) [ "$release" = 0 ] || fail "task $id records this answer as a close; retry without --release" ;;
        *) fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a captain-answer replay" ;;
      esac
      if ! close_answered "$id" "$release"; then
        fail "could not close answered captain-held task $id"
      fi
      remove_interrupted_answer_stamp "$id"
      publish_parent_resolution_then_retire "$id" $((occurrence - 1)) "$outcome"
      printf '%s: %s\n' "$outcome" "$id"
      return 0
    fi
    write_resolution_record "$id" "$outcome" "$body"
    if ! close_answered "$id" "$release"; then
      fail "could not close answered captain-held task $id"
    fi
    remove_interrupted_answer_stamp "$id"
    task_show "$id" || fail "task $id disappeared after closing"
    show=$TASK_SHOW_OUTPUT
    body_has_resolution_record "$(show_field "$show" body)" \
      || fail "captain-held task $id did not retain its durable resolution record"
    publish_parent_resolution_then_retire "$id" "$occurrence" "$outcome"
    printf '%s: %s\n' "$outcome" "$id"
    return 0
  fi

  # Not held and not closed: only an already-recorded release replays cleanly.
  if body_has_resolution_record "$body"; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different captain decision with mode ${recorded_mode:-unknown}"
    [ "$recorded_mode" = released ] && [ "$release" = 1 ] \
      || fail "task $id records this answer with mode ${recorded_mode:-unknown}; replay requires matching --release"
    remove_interrupted_answer_stamp "$id"
    publish_parent_resolution_then_retire "$id" $((occurrence - 1)) released
    printf 'released: %s\n' "$id"
    return 0
  fi
  fail "task $id is not held for the captain; hold it first or name the right task"
}

# --- attach: durable origin identity for an already-collected report --------

RESEARCH_KIND=research
RESEARCH_STATE="$STATE/captain-hold-origins"
ORIGIN_META_SOURCE=
ORIGIN_META_PATH=
ORIGIN_META_TEXT=

research_meta_path() {  # <origin-id>
  printf '%s/%s.meta\n' "$RESEARCH_STATE" "$1"
}

research_meta_access() {  # <snapshot|attest> <origin-id> [decision-keys]
  local mode=$1 origin=$2 keys=${3:-}
  perl -MFcntl=:DEFAULT,:mode -MFile::Spec -MFile::Temp=tempfile -e '
    use strict;
    use warnings;

    my ($mode, $origin, $keys, $state) = @ARGV;
    $state = File::Spec->rel2abs($state);
    my $research_state = "$state/captain-hold-origins";
    my $meta_path = "$research_state/$origin.meta";
    my $nofollow = eval { Fcntl::O_NOFOLLOW() };
    my $directory = eval { Fcntl::O_DIRECTORY() };
    exit 2 if !defined($nofollow) || !defined($directory);

    sub fd_identity {
      my ($fh, $kind) = @_;
      my @st = stat($fh);
      return if !@st;
      return if $kind eq "dir" && !S_ISDIR($st[2]);
      return if $kind eq "file" && !S_ISREG($st[2]);
      return join(":", @st[0, 1, 2]) if $kind eq "dir";
      return join(":", @st[0, 1, 2, 3, 7, 9, 10]);
    }

    sub path_identity {
      my ($path, $kind) = @_;
      my @st = lstat($path);
      return if !@st || S_ISLNK($st[2]);
      return if $kind eq "dir" && !S_ISDIR($st[2]);
      return if $kind eq "file" && !S_ISREG($st[2]);
      return join(":", @st[0, 1, 2]) if $kind eq "dir";
      return join(":", @st[0, 1, 2, 3, 7, 9, 10]);
    }

    sub fd_inode_identity {
      my ($fh) = @_;
      my @st = stat($fh);
      return if !@st || !S_ISREG($st[2]);
      return join(":", @st[0, 1]);
    }

    sub path_inode_identity {
      my ($path) = @_;
      my @st = lstat($path);
      return if !@st || S_ISLNK($st[2]) || !S_ISREG($st[2]);
      return join(":", @st[0, 1]);
    }

    sysopen(my $state_fh, $state, O_RDONLY | $nofollow | $directory) or exit 2;
    my $state_identity = fd_identity($state_fh, "dir");
    exit 2 if !defined($state_identity) || !defined(path_identity($state, "dir"))
      || path_identity($state, "dir") ne $state_identity;
    chdir($state_fh) or exit 2;
    my @namespace = lstat("captain-hold-origins");
    exit 1 if !@namespace;
    sysopen(my $research_fh, "captain-hold-origins", O_RDONLY | $nofollow | $directory) or exit 2;
    my $research_identity = fd_identity($research_fh, "dir");
    exit 2 if !defined($research_identity) || !defined(path_identity($research_state, "dir"))
      || path_identity($research_state, "dir") ne $research_identity;
    chdir($research_fh) or exit 2;
    my @meta = lstat("$origin.meta");
    exit 1 if !@meta;
    sysopen(my $meta_fh, "$origin.meta", O_RDONLY | $nofollow) or exit 2;
    binmode($meta_fh);
    my $meta_identity = fd_identity($meta_fh, "file");
    exit 2 if !defined($meta_identity) || !defined(path_identity($meta_path, "file"))
      || path_identity($meta_path, "file") ne $meta_identity;
    my $identities_valid = sub {
      return defined(fd_identity($state_fh, "dir")) && fd_identity($state_fh, "dir") eq $state_identity
        && defined(fd_identity($research_fh, "dir")) && fd_identity($research_fh, "dir") eq $research_identity
        && defined(fd_identity($meta_fh, "file")) && fd_identity($meta_fh, "file") eq $meta_identity
        && defined(path_identity($state, "dir")) && path_identity($state, "dir") eq $state_identity
        && defined(path_identity($research_state, "dir"))
        && path_identity($research_state, "dir") eq $research_identity
        && defined(path_identity($meta_path, "file")) && path_identity($meta_path, "file") eq $meta_identity;
    };
    local $/;
    my $content = <$meta_fh>;
    $content = "" if !defined($content);
    exit 2 if !$identities_valid->();
    if ($mode eq "snapshot") {
      binmode(STDOUT);
      print $content or exit 2;
      exit 2 if !$identities_valid->();
      exit 0;
    }
    exit 2 if $mode ne "attest";
    my ($tmp_fh, $tmp_name) = tempfile(".$origin.meta.complete.XXXXXX", DIR => ".", UNLINK => 1);
    binmode($tmp_fh);
    print {$tmp_fh} $content, "decisions_reviewed=1\ndecision_keys=$keys\n" or exit 2;
    my $staged_inode = fd_inode_identity($tmp_fh);
    exit 2 if !defined($staged_inode);
    close($tmp_fh) or exit 2;
    exit 2 if !$identities_valid->();
    my ($backup_fh, $backup_name) = tempfile(".$origin.meta.complete-backup.XXXXXX", DIR => ".", UNLINK => 1);
    close($backup_fh) or exit 2;
    unlink($backup_name) or exit 2;
    link("$origin.meta", $backup_name) or exit 2;
    rename($tmp_name, "$origin.meta") or do { unlink($backup_name); exit 2; };
    my $published_here = path_inode_identity("$origin.meta");
    my $published_canonical = path_inode_identity($meta_path);
    my $published_safely = defined($published_here) && $published_here eq $staged_inode
      && defined($published_canonical) && $published_canonical eq $staged_inode
      && defined(fd_identity($state_fh, "dir")) && fd_identity($state_fh, "dir") eq $state_identity
      && defined(fd_identity($research_fh, "dir")) && fd_identity($research_fh, "dir") eq $research_identity
      && defined(path_identity($state, "dir")) && path_identity($state, "dir") eq $state_identity
      && defined(path_identity($research_state, "dir"))
      && path_identity($research_state, "dir") eq $research_identity;
    if (!$published_safely) {
      if (defined($published_here) && $published_here eq $staged_inode) {
        rename($backup_name, "$origin.meta") or exit 2;
      } else {
        unlink($backup_name);
      }
      exit 2;
    }
    unlink($backup_name) or exit 2;
  ' "$mode" "$origin" "$keys" "$STATE"
}

load_origin_meta() {  # <origin-id>
  local origin=$1 live="$STATE/$1.meta" rc
  ORIGIN_META_SOURCE=
  ORIGIN_META_PATH=$(research_meta_path "$origin")
  ORIGIN_META_TEXT=
  if [ -e "$live" ] || [ -L "$live" ]; then
    [ -f "$live" ] && [ ! -L "$live" ] || fail "origin metadata is unsafe: $live"
    ORIGIN_META_TEXT=$(cat -- "$live") || fail "cannot read origin metadata: $live"
    ORIGIN_META_SOURCE=live
    ORIGIN_META_PATH=$live
    return 0
  fi
  if ORIGIN_META_TEXT=$(research_meta_access snapshot "$origin"); then
    ORIGIN_META_SOURCE=research
    return 0
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || fail "attached origin directory is unsafe: $RESEARCH_STATE"
  return 1
}

# A path segment that could walk outside the intended directory even though it
# passed validate_slug's character class (only "." and ".." are special to the
# filesystem; any other run of dots is an ordinary literal name).
is_traversal_segment() {  # <value>
  case "$1" in
    .|..) return 0 ;;
    *) return 1 ;;
  esac
}

command_attach() {
  local origin=${1:-} report report_dir
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  is_traversal_segment "$origin" && fail "origin-id must not be . or ..: $origin"
  require_tasks_axi
  [ -d "$DATA" ] && [ ! -L "$DATA" ] || fail "data directory is unsafe: $DATA"
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unsafe: $STATE"
  report_dir="$DATA/$origin"
  report="$report_dir/report.md"
  [ -d "$report_dir" ] && [ ! -L "$report_dir" ] \
    || fail "no self-contained report directory for $origin: $report_dir"
  [ -f "$report" ] && [ ! -L "$report" ] \
    || fail "no self-contained report for $origin: $report"
  [ -s "$report" ] || fail "report for $origin is empty: $report"
  pin_report_for_attach "$origin" \
    || fail "report changed or became unsafe while attaching: $report"
}

command_attach_pinned() {
  local origin=${1:-} live_meta report report_digest existing_meta existing_kind existing_digest show repo rc
  [ "$#" -eq 1 ] || exit 2
  validate_slug origin-id "$origin"
  is_traversal_segment "$origin" && fail "origin-id must not be . or ..: $origin"
  report="$DATA/$origin/report.md"
  require_tasks_axi
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || fail "state directory is unsafe: $STATE"
  show=$(task_show "$origin") \
    || fail "no backlog task $origin in $FM_HOME/data/backlog.md; attach requires an authoritative local task identity, never fabricated authority"
  repo=$(show_field_value "$show" repo)
  report_digest=$(pinned_report_guard digest "$origin") \
    || fail "report changed or became unsafe while attaching: $report"

  live_meta="$STATE/$origin.meta"
  CAPTAIN_META_LOCK=$(fm_meta_lock_path "$live_meta") || fail "could not resolve origin metadata lock"
  fm_lock_acquire_wait "$CAPTAIN_META_LOCK"
  CAPTAIN_META_LOCK_HELD=1
  pinned_report_guard check "$origin" "$report_digest" >/dev/null \
    || fail "report changed or became unsafe while attaching: $report"

  if [ -e "$live_meta" ] || [ -L "$live_meta" ]; then
    [ -f "$live_meta" ] && [ ! -L "$live_meta" ] || fail "origin metadata is unsafe: $live_meta"
    existing_kind=$(meta_value "$live_meta" kind)
    fail "task $origin already has an ordinary kind=${existing_kind:-ship} metadata record; attach is only for an origin with no live worker record"
  fi
  if existing_meta=$(research_meta_access snapshot "$origin"); then
    existing_kind=$(meta_text_value "$existing_meta" kind)
    [ "$existing_kind" = "$RESEARCH_KIND" ] \
      || fail "attached origin $origin has an invalid kind=${existing_kind:-missing} record"
    existing_digest=$(meta_text_value "$existing_meta" report_digest)
    if [ "$existing_digest" = "$report_digest" ]; then
      printf 'attached: %s (already attached, unchanged)\n' "$origin"
      return 0
    fi
    fail "origin $origin is already attached to a different report (digest mismatch); resolve the conflict before reattaching"
  else
    rc=$?
  fi
  [ "$rc" -eq 1 ] || fail "attached origin directory is unsafe: $RESEARCH_STATE"
  pinned_report_guard publish "$origin" "$report_digest" "$repo" >/dev/null \
    || fail "report, state, or attached origin directory changed or became unsafe while publishing origin metadata for $origin"
  printf 'attached: %s\n' "$origin"
}

RECONCILE_DIR="$STATE/reconcile-requests"
RECONCILE_SCHEMA=fm-reconcile-request.v1
RECONCILE_VALUE=reconcile

reconcile_request_path() { printf '%s/%s.request\n' "$RECONCILE_DIR" "$1"; }

# Idempotent per task: a repeated reconcile keeps the one request and its
# original timestamp, so a re-delivered board answer never resets the clock on
# an obligation that is already open.
reconcile_request_record() {  # <task-id> <provenance>
  local id=$1 source=$2 path tmp
  path=$(reconcile_request_path "$id")
  [ ! -e "$path" ] || return 0
  (umask 077; mkdir -p "$RECONCILE_DIR") || return 1
  [ -d "$RECONCILE_DIR" ] && [ ! -L "$RECONCILE_DIR" ] || return 1
  tmp=$(umask 077; mktemp "$RECONCILE_DIR/.request.XXXXXX") || return 1
  if {
    printf 'schema=%s\n' "$RECONCILE_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'requested=%s\n' "${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    printf 'source=%s\n' "$(sanitize_reconcile_provenance "$source")"
  } > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$path"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

reconcile_request_read() {  # <task-id>; sets RECONCILE_REQUESTED/RECONCILE_SOURCE
  local id=$1 path schema task
  path=$(reconcile_request_path "$id")
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  schema=$(sed -n 's/^schema=//p' "$path" | head -1)
  [ "$schema" = "$RECONCILE_SCHEMA" ] || fail "reconcile request has an incompatible schema: $path"
  task=$(sed -n 's/^task=//p' "$path" | head -1)
  [ "$task" = "$id" ] || fail "reconcile request names a different task: $path"
  RECONCILE_REQUESTED=$(sed -n 's/^requested=//p' "$path" | head -1)
  RECONCILE_SOURCE=$(sed -n 's/^source=//p' "$path" | head -1)
}

reconcile_request_retire() {  # <task-id>
  rm -f -- "$(reconcile_request_path "$1")" \
    || fail "could not retire the pending reconcile request for $1"
}

publish_parent_resolution_then_retire() {  # <task-id> <occurrence> <note>
  local id=$1 occurrence=$2 note=$3 request
  request=$(reconcile_request_path "$id")
  publish_parent_hold "$id" "$occurrence" resolved "$note"
  if [ -e "$request" ] && [ "$PARENT_HOLD_PUBLISHED" != 1 ]; then
    fail "could not publish the answered captain-held task $id to its parent"
  fi
  reconcile_request_retire "$id"
}


command_reconcile_requests() {
  local source_id='' source='' origin row id note provenance show show_status=0 created=0 skipped=0 tab=$'\t'
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --source-id) shift; source_id=${1:-} ;;
      --source) shift; source=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_source_id "$source_id"
  [ -n "$source" ] || fail "--source provenance is required"
  origin=$(read_binding "$source_id") || fail "cannot verify the binding for source $source_id"
  [ -n "$origin" ] || fail "source $source_id is not bound; no reconcile requests were created"
  require_tasks_axi
  while IFS= read -r row; do
    id=${row%%"$tab"*}
    note=''
    case "$row" in *"$tab"*) note=${row#*"$tab"} ;; esac
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9._-]*) printf 'refused: %s (invalid task id)\n' "$id"; skipped=$((skipped + 1)); continue ;;
    esac
    [ "${#id}" -le 128 ] \
      || { printf 'refused: %s (task id is too long)\n' "$id"; skipped=$((skipped + 1)); continue; }
    acquire_task_control_lock "$id"
    show_status=0
    show=''
    task_show "$id" || show_status=$?
    [ "$show_status" -ne 0 ] || show=$TASK_SHOW_OUTPUT
    if [ "$show_status" -eq 124 ]; then
      fail "the backlog backend exceeded its read bound reading $id"
    fi
    if [ -z "$show" ]; then
      printf 'refused: %s (absent)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field "$show" state)" = "done" ]; then
      printf 'refused: %s (already closed)\n' "$id"
      skipped=$((skipped + 1))
    elif [ "$(show_field_value "$show" hold_kind)" != captain ]; then
      printf 'refused: %s (not held for the captain)\n' "$id"
      skipped=$((skipped + 1))
    else
      provenance=$source
      [ -z "$note" ] || provenance="$source; captain note: $(sanitize_field "$note")"
      if reconcile_request_record "$id" "$provenance"; then
        printf 'reconcile: %s\n' "$id"
        created=$((created + 1))
      else
        printf 'refused: %s (cannot record the reconcile request)\n' "$id"
        skipped=$((skipped + 1))
      fi
    fi
    release_task_control_lock || fail "cannot release task control for $id"
  done
  printf 'reconcile-requests: created=%s skipped=%s\n' "$created" "$skipped"
  [ "$skipped" -eq 0 ]
}

command_reconcile() {
  local action=${1:-}
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  case "$action" in
    list)    reconcile_list "$@" ;;
    close)   reconcile_close "$@" ;;
    note)    reconcile_note "$@" ;;
    *) usage >&2; exit 2 ;;
  esac
}

reconcile_list() {
  local path id count=0
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  [ -d "$RECONCILE_DIR" ] || { printf 'reconcile-requests: 0\n'; return 0; }
  for path in "$RECONCILE_DIR"/*.request; do
    [ -e "$path" ] || continue
    id=${path##*/}; id=${id%.request}
    RECONCILE_REQUESTED=''
    RECONCILE_SOURCE=''
    reconcile_request_read "$id" || continue
    printf '%s\trequested=%s\tsource=%s\n' "$id" "$RECONCILE_REQUESTED" "$RECONCILE_SOURCE"
    count=$((count + 1))
  done
  printf 'reconcile-requests: %s\n' "$count"
}

# The moot outcome. The evidence is what closes the call, and the `reconciled`
# resolution mode is what keeps the record from claiming the captain answered.
reconcile_close() {
  local id=${1:-} evidence_file='' show state hold_kind body occurrence recorded_mode
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --evidence-file) shift; evidence_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$evidence_file" ] || fail "--evidence-file is required; a moot call closes on evidence, never on assertion"
  load_decision "$evidence_file"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  state=$(show_field "$show" state)
  hold_kind=$(show_field_value "$show" hold_kind)
  body=$(show_field "$show" body)
  occurrence=$(( $(resolution_record_count "$body") + 1 ))
  if [ "$state" = "done" ]; then
    # An exact retry finishes an interrupted close and stays idempotent; a
    # different evidence text on an already closed call is refused.
    body_has_resolution_record "$body" \
      || fail "task $id is already closed with no resolution record; use answer to record what closed it"
    [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ] \
      || fail "task $id records a different resolution; it cannot be reconciled again"
    [ "$(recorded_resolution_mode "$body" || true)" = reconciled ] \
      || fail "task $id was not closed by reconciliation"
    occurrence=$(resolution_record_count "$body")
    remove_interrupted_answer_stamp "$id"
    publish_parent_hold "$id" "$occurrence" resolved reconciled
    [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
      || fail "could not publish the reconciled captain-held task $id to its parent"
    reconcile_request_retire "$id"
    printf 'reconciled: %s\n' "$id"
    return 0
  fi
  [ "$hold_kind" = captain ] \
    || fail "task $id is not held for the captain; there is no captain call to reconcile"
  if body_has_resolution_record "$body" \
    && [ "$(recorded_decision_digest "$body" || true)" = "$DECISION_DIGEST" ]; then
    recorded_mode=$(recorded_resolution_mode "$body" || true)
    [ "$recorded_mode" = reconciled ] \
      || fail "task $id records this resolution with mode ${recorded_mode:-unknown}; it is not a reconciliation retry"
    occurrence=$(resolution_record_count "$body")
  else
    write_resolution_record "$id" reconciled "$body"
  fi
  close_answered "$id" 0 || fail "could not close reconciled captain-held task $id"
  remove_interrupted_answer_stamp "$id"
  task_show_or_fail "$id" "task $id disappeared after closing"
  body_has_resolution_record "$(show_field "$show" body)" \
    || fail "captain-held task $id did not retain its durable resolution record"
  publish_parent_hold "$id" "$occurrence" resolved reconciled
  [ "$PARENT_HOLD_PUBLISHED" = 1 ] \
    || fail "could not publish the reconciled captain-held task $id to its parent"
  reconcile_request_retire "$id"
  printf 'reconciled: %s\n' "$id"
}

# The still-active outcome. The hold survives, so the call stays the captain's
# and stays on Captain's Call, now carrying what the re-check found.
reconcile_note() {
  local id=${1:-} note_file='' note show body stamp tmp note_digest marker
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --note-file) shift; note_file=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  validate_slug task-id "$id"
  [ -n "$note_file" ] || fail "--note-file is required; leaving a call open records what the re-check found"
  [ -f "$note_file" ] || fail "note file does not exist: $note_file"
  note=$(cat "$note_file")
  [ -n "$note" ] || fail "note file must not be empty"
  [ "$(printf '%s' "$note" | LC_ALL=C wc -c | tr -d ' ')" -le 8192 ] \
    || fail "note file exceeds 8192 bytes"
  acquire_task_control_lock "$id"
  reconcile_request_read "$id" \
    || fail "task $id has no pending board-created reconcile request"
  require_tasks_axi
  command_open "$id" \
    || fail "task $id is not an open captain call; a note cannot keep a closed call open"
  task_show_or_fail "$id" "captain-held task $id is absent from this home's configured backlog (data directory $DATA)"
  body=$(decode_shown_value "$(show_field "$show" body)") \
    || fail "could not decode the existing body for $id"
  note_digest=$(sha256_text "$note")
  marker="Reconcile request: $RECONCILE_REQUESTED | $RECONCILE_SOURCE | note digest: $note_digest"
  case "$body" in
    *"$marker"*)
      reconcile_request_retire "$id" \
        || fail "could not retire the applied reconcile request for $id"
      command_open "$id" || fail "recording the reconcile note released captain-held task $id"
      printf 'still-open: %s\n' "$id"
      return 0
      ;;
  esac
  stamp=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  tmp=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-captain-hold-note.XXXXXX") \
    || fail "cannot stage the reconcile note"
  if ! printf '%s\n\nCaptain hold reconciled: %s\n%s\n%s\n' "$body" "$stamp" "$marker" "$note" > "$tmp"; then
    rm -f -- "$tmp"
    fail "cannot stage the reconcile note for $id"
  fi
  if ! tasks_axi update "$id" --body-file "$tmp" --archive-body >/dev/null; then
    rm -f -- "$tmp"
    fail "could not record the reconcile note on $id"
  fi
  rm -f -- "$tmp"
  reconcile_request_retire "$id" \
    || fail "could not retire the applied reconcile request for $id"
  command_open "$id" || fail "recording the reconcile note released captain-held task $id"
  printf 'still-open: %s\n' "$id"
}


command_complete() {
  local origin=${1:-} meta lock_meta previous='' supplied='' keys='' entry key status_file open raw_open transfer_rc
  [ "$#" -ge 2 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  shift
  lock_meta="$STATE/$origin.meta"
  CAPTAIN_META_LOCK=$(fm_meta_lock_path "$lock_meta") || fail "could not resolve task metadata lock"
  fm_lock_acquire_wait "$CAPTAIN_META_LOCK"
  CAPTAIN_META_LOCK_HELD=1
  require_tasks_axi
  origin_exists_here "$origin" || fail "origin $origin is not owned by the active home $FM_HOME"
  load_origin_meta "$origin" \
    || fail "origin metadata is absent for $origin; publish or attach authoritative metadata, then retry complete"
  meta=$ORIGIN_META_TEXT
  if [ "$#" -eq 1 ] && [ "$1" = --none ]; then
    supplied=''
  else
    while [ "$#" -gt 0 ]; do
      [ "$1" != --none ] || fail "--none cannot be combined with task ids"
      validate_slug task-id "$1"
      supplied="${supplied}${supplied:+ }$1"
      shift
    done
  fi
  previous=$(meta_text_value "$meta" decision_keys)
  keys=$(sorted_key_union "$previous" "$supplied")
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      verify_hold_durable "$(resolve_entry "$origin" "$entry")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi

  status_file="$STATE/$origin.status"
  raw_open=$(status_open_decisions "$status_file")
  open=$(origin_open_decisions "$origin")
  if [ -n "$open" ] && [ -z "$keys" ]; then
    fail "origin $origin still has open captain decisions in its status stream; hold a captain task for what remains, or answer them, before attesting --none"
  fi

  if [ "$(meta_text_value "$meta" decisions_reviewed)" != 1 ] || [ "$previous" != "$keys" ]; then
    if [ "$ORIGIN_META_SOURCE" = research ]; then
      research_meta_access attest "$origin" "$keys" \
        || fail "attached origin directory is unsafe or changed while recording completion: $RESEARCH_STATE"
    else
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$keys" >> "$ORIGIN_META_PATH"
    fi
  fi
  fm_lock_release "$CAPTAIN_META_LOCK"
  CAPTAIN_META_LOCK_HELD=0

  # Transfer every still-open status decision to the durable captain-held
  # inventory so the live status fold does not duplicate the same Captain's
  # Call item. The transfer line is this home's own bookkeeping close,
  # written by the turn that just reviewed the inventory, so it uses the
  # guarded self-announced append (bin/fm-wake-lib.sh) and does not wake this
  # same session; an append failure still fails this command loudly.
  if [ -n "$keys" ]; then
    while IFS=$'\t' read -r key _verb _summary; do
      [ -n "$key" ] || continue
      transfer_rc=0
      fm_wake_status_append_self_announced "$STATE" "$status_file" \
        "captain-held [key=$key]: tracked by $keys" || transfer_rc=$?
      [ "$transfer_rc" -ne 2 ] || fail "cannot append the captain-held transfer for $origin/$key"
    done <<EOF
$raw_open
EOF
  fi
  printf 'complete: %s captain-call inventory reviewed%s\n' "$origin" "${keys:+ ($keys)}"
}

command_verify() {
  local origin=${1:-} meta reviewed keys entry key open
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  validate_slug origin-id "$origin"
  load_origin_meta "$origin" || fail "origin metadata is absent: $ORIGIN_META_PATH"
  meta=$ORIGIN_META_TEXT
  require_tasks_axi
  reviewed=$(meta_text_value "$meta" decisions_reviewed)
  [ "$reviewed" = 1 ] || fail "origin $origin has no completed captain-call inventory"
  keys=$(meta_text_value "$meta" decision_keys)
  if [ -n "$keys" ]; then
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      verify_hold_durable "$(resolve_entry "$origin" "$entry")"
    done <<EOF
$(printf '%s\n' "$keys" | tr ',' '\n')
EOF
  fi
  open=$(origin_open_decisions "$origin")
  while IFS=$'\t' read -r key _verb _summary; do
    [ -n "$key" ] || continue
    fail "open captain decision $origin/$key is not transferred to the captain-held inventory; re-run complete"
  done <<EOF
$open
EOF
  printf 'verified: %s captain-call inventory\n' "$origin"
}

# --- record divergence ------------------------------------------------------
#
# A captain call can be written down twice, and until now nothing said when
# those two records disagreed. A `resolved [key=...]` line closes the status-log
# fold outright; the structured captain-held task is closed by a SEPARATE act
# (`answer` above). Closing only on the status side therefore looks complete
# there while the durable record still says the captain owes an answer and
# keeps resurfacing it. The defect was never the separation; it was the silence.
#
# `diverged` is a read-only report of that contradiction and nothing else. It
# closes NOTHING. A captain call closed wrongly disappears without review, which
# is strictly worse than the noise this prints, so reconciling a divergence stays
# a human-owned act - and it runs in either direction: record what the captain
# actually said with `answer`, or re-open the status decision when that
# resolution was not the captain's word.
#
# What it flags, and only this: a task that is still open and still carries the
# captain-hold annotations, whose key was closed on the status side by the
# RESOLVE verb. The other closing verb is not a divergence: a `captain-held`
# close is the VERIFIED transfer to that very task, written by command_complete
# only after verifying it, so the structured row staying open behind it is the
# correct state. Neither is a still-open status decision - the OPEN DECISIONS
# fold already owns that one.
#
# Routed work is deliberately irrelevant. When the decision IS the deliverable
# there is nothing to route, so the test is only whether the status side already
# declared this task's key resolved.
# Nor does the report interpret why that resolution exists. A call can turn out
# not to be a captain arbitration at all - a premise can dissolve, or a question
# of fact can prove its first reading wrong - so the report says only that the
# two records disagree and names both reconciliation directions above.
#
# Cost stays flat on a healthy home: one `tasks-axi list`, one key scan per
# status log, and the precise per-key fold only for a key that already names a
# still-open task. If tasks-axi is unavailable or its listing cannot be parsed,
# the guard cannot read the structured record and prints nothing.
#
# Output: one `<task-id>\t<origin>\t<key>\t<title>` line per divergence, in
# status-log then key order; nothing when the two records agree.

# Every still-open task id in this home's backlog, one per line. Only the first
# two comma-separated listing fields are read - both are slugs that precede any
# quoted title - so a title containing commas or quotes cannot shift them.
open_task_ids() {
  tasks_axi list 2>/dev/null | awk -F, '
    /^  [A-Za-z0-9._-]+,/ {
      id = $1
      sub(/^ +/, "", id)
      if ($2 != "done") print id
    }
  '
}

# Every key token stated anywhere in a status log. A cheap candidate scan: it
# over-includes tokens that are only prose, and status_key_closing_verb below is
# what actually decides what the stream says about a key.
status_log_key_tokens() {  # <status-file>
  grep -o '\[key=[A-Za-z0-9._-]*\]' "$1" 2>/dev/null |
    sed 's/^\[key=//; s/\]$//' | LC_ALL=C sort -u
}

list_has_line() {  # <newline-separated-list> <value>
  case $'\n'"$1"$'\n' in
    *$'\n'"$2"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

command_diverged() {
  local ids resolve f origin tokens id keys key show title
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  # Both records must belong to the SAME home or the comparison is meaningless:
  # tasks-axi reads $FM_HOME's backlog, so a state dir pointed somewhere else
  # would report one home's status logs against another home's tasks. Every
  # production caller pairs the two; a mismatch stays silent rather than
  # inventing a cross-home divergence.
  [ "$STATE" = "$FM_HOME/state" ] || return 0
  # A read-only listing on a per-wake path, so it skips the mutation-oriented
  # compatibility floor and its extra probes: a listing this parser cannot read
  # simply yields no candidates and the report stays silent.
  command -v tasks-axi >/dev/null 2>&1 || return 0
  ids=$(open_task_ids) || return 0
  [ -n "$ids" ] || return 0
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  for f in "$STATE"/*.status; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    origin=$(basename "$f"); origin=${origin%.status}
    tokens=$(status_log_key_tokens "$f")
    [ -n "$tokens" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # The keys that could name this task in THIS log: the collapsed identity
      # (the key IS the task id) and, for a pre-collapse row, the legacy derived
      # one this origin would have minted.
      keys=$id
      case "$id" in
        "$origin-decision-"?*) keys="$keys"$'\n'"${id#"$origin-decision-"}" ;;
      esac
      while IFS= read -r key; do
        list_has_line "$tokens" "$key" || continue
        [ "$(status_key_closing_verb "$f" "$key")" = "$resolve" ] || continue
        show=$(task_show "$id") || continue
        [ "$(show_field "$show" state)" != "done" ] || continue
        [ "$(show_field_value "$show" hold_kind)" = captain ] || continue
        # The title is the only free-text field here, and the report is
        # TAB-separated, so it goes through the same sanitizer every other
        # emitted field uses rather than being trusted to stay one clean line.
        title=$(sanitize_field "$(show_field_value "$show" title)")
        printf '%s\t%s\t%s\t%s\n' "$id" "$origin" "$key" "$title"
        break
      done <<INNER
$keys
INNER
    done <<EOF
$ids
EOF
  done
}

command_open() {  # <task-id> [--identity] [--distinguish-absent]
  local id='' identity=0 distinguish_absent=0 data state root file backend show shown_body
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --identity) identity=1 ;;
      --distinguish-absent) distinguish_absent=1 ;;
      -*) usage >&2; exit 2 ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 2; }
        id=$1
        ;;
    esac
    shift
  done
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      printf 'fm-captain-hold: task id must be a non-empty privacy-safe slug: %s\n' "$id" >&2
      exit 2
      ;;
  esac
  data=$(fm_backlog_data_absolute "$DATA") \
    || { printf 'fm-captain-hold: data directory cannot be resolved: %s\n' "$DATA" >&2; exit 2; }
  root=$(fm_backlog_root "$data") \
    || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
  if ! backend=$(fm_tasks_axi_backend_resolve "$root"); then
    exit 2
  fi
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") \
      || { printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2; exit 2; }
    if [ ! -e "$file" ] && [ ! -L "$file" ]; then
      # No backlog file at all: this home records no captain calls, so the task
      # is absent from it rather than held. A record that EXISTS but cannot be
      # read is a different state and still leaves by the exit 2 paths below,
      # because that one may hide a live hold.
      [ "$distinguish_absent" = 0 ] || return 3
      return 1
    fi
  fi
  fm_tasks_axi_compatible || { printf 'fm-captain-hold: compatible tasks-axi is required\n' >&2; exit 2; }
  if fm_backlog_row_probe "$data" "$id"; then
    state=${FM_BACKLOG_ROW_STATE%% *}
    if [ "$state" != "done" ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
      if [ "$identity" -eq 1 ]; then
        show=$(task_show "$id") || {
          printf 'fm-captain-hold: captain call %s is open but its record could not be read\n' "$id" >&2
          exit 2
        }
        shown_body=$(show_field "$show" body)
        printf '%s#%s\n' \
          "$(body_hold_set_timestamp "$(decode_shown_value "$shown_body")")" \
          "$(resolution_record_count "$shown_body")"
      fi
      return 0
    fi
    return 1
  fi
  if [ "$FM_BACKLOG_ROW_RESULT" = not_found ]; then
    [ "$distinguish_absent" = 0 ] || return 3
    return 1
  fi
  printf 'fm-captain-hold: %s\n' "$FM_BACKLOG_ROW_ERROR" >&2
  exit 2
}


case "${1:-}" in
  hold) shift; command_hold "$@" ;;
  answer) shift; command_answer "$@" ;;
  answers) shift; command_answers "$@" ;;
  bind) shift; command_bind "$@" ;;
  unbind) shift; command_unbind "$@" ;;
  binding) shift; command_binding "$@" ;;
  reconcile-requests) shift; command_reconcile_requests "$@" ;;
  complete) shift; command_complete "$@" ;;
  verify) shift; command_verify "$@" ;;
  attach) shift; command_attach "$@" ;;
  __attach-pinned) shift; command_attach_pinned "$@" ;;
  open) shift; command_open "$@" ;;
  diverged) shift; command_diverged "$@" ;;
  reconcile) shift; command_reconcile "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
