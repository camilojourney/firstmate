# Pi orphan-border live validation

## Environment and isolation

- Real installed Pi 1.4.0 in a private tmux 3.8 server, 100 columns × 24 rows. tmux provided and drained a non-zero-sized PTY before Pi started.
- A marked disposable Firstmate home, isolated HOME and PI_CODING_AGENT_DIR, synthetic session records, metadata, and socket all lived in `.live-pi-lab` inside the validation worktree. The home and server were removed after testing.
- Pi ran offline with extensions, MCP, tools, skills, context files, templates, and theme discovery disabled. It loaded an explicitly synthetic assistant markdown table through its real `--session` interface. No model request or operator authentication was needed. The no-model warning in the screenshots is intentional; the footer's `unknown` identifies the absent model, not the Firstmate composer verdict.
- No Herdr session, operator home, installed local Firstmate copy, or production credentials were changed. Publication belongs to the outer executor, not this test phase.

## Runtime path actually exercised

The changed path is the shared **cursorless** composer selector. We called the real `fm_composer_classify_screen` interface with fresh ANSI captures of the running Pi TUI, `styled=1`, `cursor=0`, `identity=1`, and the real Pi identity/status obtained with `fm_tmux_composer_identity`. We deliberately omitted cursor metadata, rather than claiming tmux's cursor-aware adapter exercised this change.

For the regression comparison, the base commit's composer library was extracted into the disposable home and executed against the same fresh live screen and identity. Base returned `unknown`; target returned `empty`.

Separately, the real `bin/fm-control.sh` CLI was driven through its normal tmux adapter. Its successful exit is a tmux lifecycle proof, not a native Herdr restart/relaunch proof. Both exit and relaunch refused a typed draft without changing the viewport. An initial numeric-window metadata setup was rejected safely, then corrected to the documented `primary:fm-orphan` binding before re-running these checks.

## Observed scenarios

| User action | Observable product result |
| --- | --- |
| Open a long markdown-table answer so its top border scrolls out of the viewport, leaving its bottom border above the empty Pi composer | Base cursorless classifier: `unknown`; target: `empty` |
| Type `fix the flaky test`, then request exit and relaunch | Cursorless classifier: `pending`; both real control commands refuse; complete viewport remains byte-identical |
| Type `└────────────┘` inside the composer | Cursorless classifier: `unknown`; exit refuses because the composer is not proven empty |
| Clear the draft, then request exit | Cursorless classifier: `empty`; control CLI reports `stopped orphan harness=pi backend=tmux`; endpoint survives with bash in the foreground |
| Inspect the leftover shell after Pi exits | Real identity probe returns no Pi identity; cursorless classifier returns `unknown`, not `empty` |

## Evidence

- `live-pi-transcript.txt`: direct product output, actual screen contents, verdicts, lifecycle refusals/success, and cleanup.
- `idle-pi.png`, `typed-pi.png`, `border-draft-pi.png`: visual images rendered from actual live ANSI terminal captures, not reconstructed UI mockups. Matching `.ansi` and `.svg` files preserve the capture and rendering input.
- `render-terminal-evidence.py`: ANSI-to-SVG rendering; PNGs were produced with `sips -s format png <svg> --out <png>`.
- `composer-targeted-tests.log`: successful targeted existing `bash tests/fm-composer-lib.test.sh` execution, including the new fixtures and idle/done, typed, working, and overlapping-border checks. These fixture tests are supplemental, not claimed as live scenarios.

No linters, formatters, static analysis, broad repository suite, delivery commands, or other pipeline phases were run. No source or test files were changed. The final worktree was clean.
