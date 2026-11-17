# SimpleMotion / SimpleWhichKey interaction gate

## Reproduce

Requires Vim 9.1+ with popupwin, textprop, timers and vim9script, Python 3,
and a POSIX PTY. No pip dependencies, personal vimrc or desktop are used.

```sh
# From a SimpleMotion checkout; obtain the dependency explicitly.
git clone https://github.com/beamiter/simplewhichkey ../simplewhichkey
git -C ../simplewhichkey checkout 86e75d0bce8e1d3a35915c887c52a226241b0c2a
SIMPLEWHICHKEY_ROOT=../simplewhichkey make check-integration
```

`make check` remains the standalone gate. `make test-whichkey` runs just the
combined suite. `SIMPLEWHICHKEY_ROOT` defaults to a sibling `simplewhichkey`
checkout; a missing dependency fails, never silently skips. The Python runner
accepts `VIM=/absolute/path/to/vim`; put that Vim on PATH for existing Makefile
checks. CI checks out the companion revision above and runs `check-integration`.
That pin includes the replay-order fix in SimpleWhichKey PR #1. It is deliberately
not a moving master ref; update it explicitly when accepting a newer dependency.

## Why another suite

The existing `jump_lifecycle.py` tests Motion alone: unchanged targets, edits,
replaced buffers, closed windows and WinEnter edits/closure. WhichKey's existing
`vim_keys_context.vim` tests buffer/window/text changes, its initial delay, and
unchanged choices; its other key tests cover replay, macros, operators and
interrupt cleanup. None loads both plugins or tests their handoff.

The combined suite owns only that integration boundary. It loads both real
plugins, maps `zx`/`zf` to Motion's public <Plug> mappings, and opens WhichKey
with actual PTY input. A timer-based request/reply driver observes popup owners
and makes explicit context mutations while Vim is really waiting for input.
Input is sent only after the preceding state is observed; five-second deadlines
bound failures rather than deciding when a popup is assumed to exist.

| Scenario | Expected result |
| --- | --- |
| WhichKey -> Motion -> WhichKey, repeated | Correct jump, hooks restored, no leaked popup |
| Choice and search arguments in one `fzz` PTY write | Replay precedes queued arguments; search succeeds |
| Window switch, timer edit, User autocmd edit, replacement buffer, closure, close/reopen during WhichKey | Old choice cannot start Motion; a fresh choice works |
| Timer/autocmd edit, replacement, closure, close/reopen during Motion labels | Old label cannot move the new context; a fresh choice works |
| Window switch during labels with original target intact | Jump to the still-valid original target remains supported |
| Same mutations during first/second search-character waits | Cancel before collecting targets in the changed context |
| WinEnter edits the destination after cross-window selection | Do not apply the stale destination position |
| Escape, FocusLost event then Escape, externally closed popups then Escape | Both plugins recover and reopen independently |

Each mutation asserts window, buffer, cursor and contents, not just popup
absence. `close_reopen` opens the original buffer in a new window, checking that
buffer identity alone cannot rescue an old window ID. The driver also checks
Vim errors. Every cancellation is followed by a successful WhichKey command.

## Findings and validation (2026-11-17)

Baseline masters: Motion `c744cdb30df72a52802743ad82acb5c6f2f238ed`, WhichKey
`229d5aa98782eb5e2d46d3bb6cb9517b10ef48e8`.

Two defects were reproduced; neither requires assuming the other plugin is
broken:

1. WhichKey appended a selected shortcut behind queued argument keys. With the
   panel open, `fzz` left Motion waiting for search characters. Prepending its
   replay (`feedkeys(..., 'mit')`) fixes the order. The independent
   `vim_replay_order.vim` fails on baseline and passes on the companion revision.
2. Motion guarded selected targets but not the earlier search-input waits.
   Replacing the buffer between search characters let the old search select and
   jump in the replacement buffer. Capture/check window, buffer and changedtick
   after each search character. The independent lifecycle regression expects
   line 3 and observes line 2 on baseline; it passes with the fix.

Local validation used Debian Vim 9.1.1230 with patches 1242/1244 included.
Both standalone `make check` gates passed, as did all eight combined test groups
(including their mutation subcases). The local Vim lacks clipboard support;
WhichKey explicitly skipped its +/* clipboard-register substeps.

Scope: FocusLost is dispatched as a Vim autocommand event, not an OS desktop
focus transfer. The tests do not claim coverage of compositor input delivery,
terminal reconnections, every Vim build, or arbitrary third-party reentrant
callbacks. Cancellation is checked when the pending input arrives; immediate
popup dismissal before any further input is not promised by either plugin.
