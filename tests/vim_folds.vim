vim9script

# Viewport guard.
#
#   vim -N -u NONE -n -es -S tests/vim_folds.vim
#
# A hint is a promise that the thing under it is on the screen, and both
# scanners used to break that promise on a folded buffer.  getwininfo()'s
# botline counts buffer lines rather than screen rows, so one closed fold
# hiding 19989 lines reported topline=1 botline=19999 for a window showing 11
# rows -- and LineTargets(), which had no cap either, answered
# :SimpleMotionDown with 19998 targets, 19988 of them on lines inside the fold,
# every one resolving to the single row the fold occupies.  Raising and tearing
# down that many popups took 61 seconds, measured, on the buffer this file
# builds.
#
# Timing assertions would be worthless here -- a loaded machine makes them lie
# in both directions -- so the budget is expressed as the two things that
# actually scale: how many buffer lines a scan walks, and how many popups a
# jump raises.  Those go red the moment either starts tracking the size of the
# file again, whatever the machine is doing.

set nocompatible nomore
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simplemotion.vim')

def Lnums(targets: list<dict<any>>): list<number>
  return mapnew(targets, (_, target) => target.lnum)
enddef

# A line is displayed when it is outside every closed fold, or is the one line
# of it that the fold draws.
def Displayed(lnum: number): bool
  var start = foldclosed(lnum)
  return start < 0 || start == lnum
enddef

# ---------------------------------------------------------------------------
# A 20000-line buffer folded down to a handful of rows.
new
setline(1, mapnew(range(20000), (_, i) => $'    body line {i} with ab text'))
# 'nowrap' so a row is always exactly one buffer line: the expectations below
# are screen-row arithmetic, and a narrow terminal wrapping the fixture text
# would change how many lines fit without changing anything being tested.
setlocal foldmethod=manual foldenable nowrap
:2,19990fold
cursor(1, 1)
var info = getwininfo(win_getid())[0]

# Vim honours $LINES even under -es, where there is no terminal to ask, and
# :set lines= does not re-lay-out the windows there -- so the window is however
# tall the invoking shell says it is and cannot be pinned from in here.  The
# expectations are therefore derived from the height rather than hard-coded:
# hard-coding them made this file fail four assertions under LINES=50 and three
# under LINES=12 with nothing whatever wrong with the plugin.
#
# The window draws line 1, then one row of foldtext() for the closed 2..19990,
# then as many of the ten lines after the fold as still fit.
const TAIL_FIRST = 19991
const TAIL = min([info.height - 2, 20000 - TAIL_FIRST + 1])
assert_true(TAIL >= 3,
  $'fixture needs a window of at least 5 rows, got {info.height}: run with '
  .. '$LINES unset or >= 18')
const TAIL_LNUMS = range(TAIL_FIRST, TAIL_FIRST + TAIL - 1)

# The fixture only means anything if botline really does run past the screen;
# if a future Vim reports botline in screen rows this test would pass without
# ever exercising the fold walk.
assert_equal(1, info.topline)
assert_equal(TAIL_FIRST + TAIL - 1, info.botline,
  'fixture is wrong: botline must run past the window for this to test anything')
assert_true(info.botline - info.topline + 1 > info.height * 100,
  'fixture is wrong: the fold must hide far more lines than the window shows')

# --- the viewport invariant ------------------------------------------------
var before = simplemotion#Counters()
var down = simplemotion#LineTargets('down')
var walked = simplemotion#Counters().scanned - before.scanned

assert_equal([2] + TAIL_LNUMS,
  Lnums(down),
  'every target below the cursor must be a row on the screen: the closed fold '
  .. 'is one target at its first line, then the lines after it')
for target in down
  assert_true(Displayed(target.lnum),
    $'target on line {target.lnum} is hidden inside a closed fold')
endfor
assert_true(len(down) <= info.height,
  $'{len(down)} targets for a window {info.height} rows tall')
assert_true(walked <= info.height,
  $'walked {walked} buffer lines to fill a window {info.height} rows tall')

# The two-character search must not offer a hint for text the fold covers: the
# fold's row draws foldtext(), never the buffer line underneath it.
before = simplemotion#Counters()
var found = simplemotion#FindTargets('ab', false)
walked = simplemotion#Counters().scanned - before.scanned
assert_equal([1] + TAIL_LNUMS,
  Lnums(found), 'matches inside a closed fold are not on the screen')
for target in found
  assert_equal(-1, foldclosed(target.lnum),
    $'match on line {target.lnum} is covered by a closed fold')
endfor
assert_true(walked <= info.height,
  $'walked {walked} buffer lines to search a window {info.height} rows tall')

# A needle that matches nothing cannot lean on the target cap to stop early, so
# it is the walk itself that has to be bounded.
before = simplemotion#Counters()
assert_equal([], simplemotion#FindTargets('zqx', false))
walked = simplemotion#Counters().scanned - before.scanned
assert_true(walked <= info.height,
  $'a search that matches nothing walked {walked} lines of a {info.height}-row window')

# --- the cap LineTargets never applied -------------------------------------
g:simplemotion_max_targets = 4
assert_equal([2] + TAIL_LNUMS[0 : 2], Lnums(simplemotion#LineTargets('down')),
  'LineTargets must honour g:simplemotion_max_targets, and keep the targets '
  .. 'nearest the cursor rather than the farthest')
g:simplemotion_max_targets = 500

# --- the popups a jump raises ----------------------------------------------
# Driving the real command end to end is the only way to count what ShowHints
# actually creates, since Jump() closes every popup before it returns.
cursor(1, 1)
before = simplemotion#Counters()
feedkeys("\<Esc>", 'nt')
simplemotion#Jump('down')
var popups = simplemotion#Counters().hinted - before.hinted
assert_true(popups <= info.height,
  $'one :SimpleMotionDown raised {popups} popups for a {info.height}-row window')
assert_equal([], popup_list(), 'Jump left popups behind')

# ---------------------------------------------------------------------------
# Folds belong to a window, not to a buffer: the visible-line probe runs inside
# each window through win_execute() precisely because foldclosed() answers only
# for the current one.  Reading the wrong window's folds would silently drop
# matches, so a folded window and an unfolded one are searched together here.
new
setline(1, mapnew(range(12), (_, i) => $'ab plain {i}'))
var plain = win_getid()
assert_equal(-1, foldclosed(3), 'the second window must have no folds of its own')
var plain_info = getwininfo(plain)[0]

var across = simplemotion#FindTargets('ab', true)
var per_window: dict<number> = {}
for target in across
  per_window[target.winid] = get(per_window, target.winid, 0) + 1
endfor
# One 'ab' per line, so an unfolded window owes exactly one match per row it
# displays.  Fewer means the other window's folds were applied to this one.
assert_equal(plain_info.botline - plain_info.topline + 1, get(per_window, plain, 0),
  'the unfolded window lost matches to the other window''s folds')
for target in across
  var closed = str2nr(trim(win_execute(target.winid, $'echo foldclosed({target.lnum})')))
  assert_equal(-1, closed,
    $'window {target.winid} line {target.lnum} sits under a closed fold')
endfor

# ---------------------------------------------------------------------------
# Walking 'up' must come back nearest-first.  It is collected descending for
# that reason: gathering it ascending and reversing, as it once did, let the cap
# throw away the lines next to the cursor and keep the far ones.
new
setline(1, ['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight'])
cursor(6, 1)
assert_equal(1, getwininfo(win_getid())[0].topline)
assert_equal([5, 4, 3, 2, 1], Lnums(simplemotion#LineTargets('up')),
  'targets above the cursor must be ordered outward from it')

g:simplemotion_max_targets = 2
assert_equal([5, 4], Lnums(simplemotion#LineTargets('up')),
  'the cap must drop the lines farthest from the cursor, not the nearest')
g:simplemotion_max_targets = 500

# A closed fold above the cursor is one row and earns one target, sitting in the
# order its row occupies on the screen: line 1 is still above it and still its
# own row.
setlocal foldmethod=manual foldenable
:2,4fold
cursor(7, 1)
var above = simplemotion#LineTargets('up')
assert_equal([6, 5, 2, 1], Lnums(above),
  'the closed fold above the cursor must collapse to a single target at its '
  .. 'first line, and must not swallow the line above it')
assert_equal(1, above[2].col,
  'a fold row draws foldtext(), so its hint belongs at column 1')

if !empty(v:errors)
  for error in v:errors
    echomsg error
  endfor
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit 1
endif
echomsg '[SimpleMotion] fold and viewport tests passed'
qall!
