vim9script

set nocompatible nomore
set cmdheight=20
const ROOT = fnamemodify(resolve(expand('<sfile>:p')), ':h:h')
execute 'set runtimepath^=' .. fnameescape(ROOT)
execute 'source ' .. fnameescape(ROOT .. '/plugin/simplemotion.vim')

new
setline(1, ['ab one ab', 'nothing', 'AB smartcase', 'ab last'])
var targets = simplemotion#FindTargets('ab', false)
assert_equal([[1, 1], [1, 8], [3, 1], [4, 1]],
  mapnew(targets, (_, target) => [target.lnum, target.col]))
g:simplemotion_smartcase = 1
targets = simplemotion#FindTargets('AB', false)
assert_equal([[3, 1]], mapnew(targets, (_, target) => [target.lnum, target.col]))

# Smartcase is not limited to ASCII capitals.  An uppercase multibyte needle
# must not also select its lowercase spelling.
setline(1, ['Äb', 'äb'])
if line('$') > 2
  deletebufline('%', 3, line('$'))
endif
targets = simplemotion#FindTargets('Äb', false)
assert_equal([[1, 1]], mapnew(targets, (_, target) => [target.lnum, target.col]),
  'Unicode uppercase was treated as a case-insensitive smartcase needle')
setline(1, ['ab one ab', 'nothing', 'AB smartcase', 'ab last'])

# The cap is a literal upper bound. Zero disables target collection instead of
# leaking the first match through the add-then-check loop; bad runtime config
# falls back safely rather than throwing from a motion.
g:simplemotion_max_targets = 2
assert_equal(2, len(simplemotion#FindTargets('ab', false)))
g:simplemotion_max_targets = 0
assert_equal([], simplemotion#FindTargets('ab', false))
assert_equal([], simplemotion#LineTargets('down'))
g:simplemotion_max_targets = -7
assert_equal([], simplemotion#FindTargets('ab', false))
g:simplemotion_max_targets = 'not-a-number'
assert_equal(4, len(simplemotion#FindTargets('ab', false)))
g:simplemotion_max_targets = v:true
assert_equal(4, len(simplemotion#FindTargets('ab', false)),
  'a bool is an invalid numeric cap and falls back to 500')
g:simplemotion_max_targets = v:false
assert_equal(4, len(simplemotion#FindTargets('ab', false)))
g:simplemotion_max_targets = 500

g:simplemotion_keys = []
assert_equal(3, len(simplemotion#LabelCodes(3)),
  'a malformed key alphabet falls back instead of breaking the motion')
g:simplemotion_keys = 'asdfghjklqwertyuiopzxcvbnm'
g:simplemotion_smartcase = {}
assert_equal([[3, 1]],
  mapnew(simplemotion#FindTargets('AB', false), (_, target) => [target.lnum, target.col]),
  'a malformed smartcase flag falls back to the documented default')
g:simplemotion_smartcase = 1

# One unique key is not enough to build codes; fall back rather than looping
# forever (`capacity *= 1`) or emitting identical labels.
g:simplemotion_keys = 'aaa'
var early_labels = simplemotion#LabelCodes(3)
assert_equal(3, len(uniq(sort(copy(early_labels)))),
  'a single unique key was used as the alphabet')
g:simplemotion_keys = 'asdfghjklqwertyuiopzxcvbnm'
assert_equal([], simplemotion#LabelCodes(0))
assert_equal([], simplemotion#LabelCodes(-3))
assert_equal([], simplemotion#FindTargets('', false))

# Blank lines are not line-motion targets, and the line under the cursor is
# never offered as a target below it.
setline(1, ['one', '', 'three', 'four'])
if line('$') > 4
  deletebufline('%', 5, line('$'))
endif
cursor(1, 1)
assert_equal([3, 4], mapnew(simplemotion#LineTargets('down'), (_, t) => t.lnum))
cursor(4, 1)
assert_equal([], simplemotion#LineTargets('down'))
assert_equal([3, 1], mapnew(simplemotion#LineTargets('up'), (_, t) => t.lnum))
setline(1, ['ab one ab', 'nothing', 'AB smartcase', 'ab last'])
cursor(1, 1)

for count in [1, 2, 26, 27, 200]
  var labels = simplemotion#LabelCodes(count)
  assert_equal(count, len(labels))
  assert_equal(count, len(uniq(sort(copy(labels)))))
endfor

# A visible line can have hidden columns.  Under 'nowrap', codes must only be
# assigned to matches screenpos() can actually draw; otherwise the user can
# type an undisplayed code, and hidden matches can exhaust the cap before a
# visible match is collected.
only
setlocal nowrap
var viewport = winwidth(0)
var scroll = viewport
var first_visible = scroll + 3
var last_visible = scroll + viewport - 3
setline(1, 'ab' .. repeat('x', first_visible - 3) .. 'ab'
  .. repeat('y', last_visible - first_visible - 2) .. 'ab')
if line('$') > 1
  deletebufline('%', 2, line('$'))
endif
cursor(1, first_visible)
winrestview({lnum: 1, col: first_visible, topline: 1, leftcol: scroll})
targets = simplemotion#FindTargets('ab', false)
assert_equal([[1, first_visible], [1, last_visible]],
  mapnew(targets, (_, target) => [target.lnum, target.col]),
  'horizontally hidden matches were offered without popup labels')

# A minified nowrap line must begin matching at the visible byte, not call
# screenpos() for every hidden occurrence to its right.  Probe count is a
# deterministic complexity assertion; the old path made 50,000 calls here.
setline(1, repeat('ab', 50000))
cursor(1, 1)
winrestview({lnum: 1, col: 1, topline: 1, leftcol: 0})
var before_probes = simplemotion#Counters().probed
targets = simplemotion#FindTargets('ab', false)
var probe_cost = simplemotion#Counters().probed - before_probes
assert_true(probe_cost <= winwidth(0),
  $'nowrap scan probed {probe_cost} matches for a {winwidth(0)}-column window')

setlocal wrap
before_probes = simplemotion#Counters().probed
targets = simplemotion#FindTargets('ab', false)
probe_cost = simplemotion#Counters().probed - before_probes
assert_true(probe_cost <= (winheight(0) + 2) * winwidth(0),
  $'wrapped scan probed {probe_cost} matches outside the visible screen rows')

# A result at the final displayed column may finish outside the viewport.
# Only the match start is a hint anchor, and its second character may be wide.
setlocal nowrap nonumber norelativenumber signcolumn=no foldcolumn=0 sidescrolloff=0
var width = winwidth(0)
var shift = 19
var right = shift + width
setline(1, repeat('x', right - 1) .. 'a界' .. repeat('x', 400))
cursor(1, right - 5)
winrestview({lnum: 1, col: right - 6, topline: 1, leftcol: shift})
redraw!
assert_true(screenpos(win_getid(), 1, right).col > 0, 'fixture starts in last visible cell')
assert_equal(0, screenpos(win_getid(), 1, right + 1).col, 'fixture wide tail is off-screen')
assert_equal([[1, right]], mapnew(simplemotion#FindTargets('a界', false),
  (_, target) => [target.lnum, target.col]), 'right-edge match was truncated')
setline(1, repeat('x', right - 1) .. 'aK' .. repeat('x', 400))
winrestview({lnum: 1, col: right - 6, topline: 1, leftcol: shift})
redraw!
assert_equal([[1, right]], mapnew(simplemotion#FindTargets('ak', false),
  (_, target) => [target.lnum, target.col]),
  'lowercase k must match a wider case-equivalent character beyond the right edge')

# Match starts and absolute UTF-8 byte columns must agree with the actual
# screen layout across tabs, wide text and both wrap modes. This oracle
# deliberately scans the short fixture without the production byte bounds.
def VisibleLiteral(query: string): list<list<number>>
  var found: list<list<number>> = []
  for lnum in range(1, line('$'))
    var text = getline(lnum)
    var start = 0
    while start < strlen(text)
      var byte = match(text, '\V' .. escape(query, '\'), start, 1)
      if byte < 0
        break
      endif
      var cell = screenpos(win_getid(), lnum, byte + 1)
      if cell.row > 0 && cell.col > 0
        found->add([lnum, byte + 1])
      endif
      start = byte + 1
    endwhile
  endfor
  return found
enddef

setlocal tabstop=8
setline(1, repeat(['界é' .. "\t" .. 'ab界é' .. "\t" .. 'x'], 130)->join(''))
for wrapped in [false, true]
  &l:wrap = wrapped
  cursor(1, 39)
  winrestview({lnum: 1, col: 38, topline: 1, leftcol: wrapped ? 0 : 27})
  redraw!
  for needle in ['界é', 'ab', "é\t"]
    var expected = VisibleLiteral(needle)
    assert_true(len(expected) > 0, $'fixture {needle} mode {wrapped} has no target')
    assert_equal(expected, mapnew(simplemotion#FindTargets(needle, false),
      (_, target) => [target.lnum, target.col]), $'viewport layout mismatch for {needle}, wrap={wrapped}')
  endfor
endfor

# A long hidden suffix with no match (or only a late hidden match) still
# consumes regex work, although neither case increments the screenpos probe
# counter. Budget the regex input rather than relying on CI wall-clock noise.
for wrapped in [false, true]
  &l:wrap = wrapped
  for tail in ['', 'ab']
    setline(1, repeat('x', 1024 * 1024) .. tail)
    cursor(1, 1)
    winrestview({lnum: 1, col: 0, topline: 1, leftcol: 0, skipcol: 0})
    redraw!
    var bytes_before = simplemotion#Counters().regex_bytes
    assert_equal([], simplemotion#FindTargets('ab', false))
    var bytes = simplemotion#Counters().regex_bytes - bytes_before
    var budget = wrapped ? (winheight(0) + 3) * winwidth(0) + 8 : winwidth(0) + 8
    assert_true(bytes <= budget, $'regex received {bytes} bytes, budget {budget}, wrap={wrapped}')
  endfor
endfor
setlocal wrap

# With cpo-n, wrapped continuation rows reclaim the number column.  The scan
# bound must use that wider row or it can cut off a target that screenpos says
# is on the final visible row.
var saved_cpo = &cpoptions
set cpoptions+=n number numberwidth=4 signcolumn=yes foldcolumn=2
var wrap_info = getwininfo(win_getid())[0]
var old_wrap_bound = (wrap_info.height + 1) * (wrap_info.width - wrap_info.textoff)
var near_bottom = old_wrap_bound + 5
setline(1, repeat('x', near_bottom - 1) .. 'ab' .. repeat('y', 100))
cursor(1, 1)
normal! zt
var bottom_screen = screenpos(win_getid(), 1, near_bottom)
assert_true(bottom_screen.row > 0, 'wrapped-bound fixture target is not visible')
targets = simplemotion#FindTargets('ab', false)
assert_equal([[1, near_bottom]],
  mapnew(targets, (_, target) => [target.lnum, target.col]),
  'cpo-n continuation width cut off a visible wrapped target')
if exists('+smoothscroll')
  set smoothscroll
  setline(1, repeat('x', 152) .. 'ab' .. repeat('y', 3000))
  cursor(1, 200)
  winrestview({lnum: 1, col: 200, topline: 1, skipcol: 160})
  redraw!
  if screenpos(win_getid(), 1, 153).row > 0
    targets = simplemotion#FindTargets('ab', false)
    assert_equal([[1, 153]], mapnew(targets, (_, target) => [target.lnum, target.col]),
      'smoothscroll skipcol cut off a still-visible match')
  endif
  set nosmoothscroll
endif
&cpoptions = saved_cpo
set nonumber signcolumn=auto foldcolumn=0

# getwininfo().botline excludes a line whose first wrapped row occupies the
# bottom screen row while the rest continues below it.
resize 23
var bottom_line = max([2, winheight(0) - 1])
setline(1, repeat(['short'], bottom_line - 1) + ['ab' .. repeat('x', 500)])
if line('$') > bottom_line
  deletebufline('%', bottom_line + 1, line('$'))
endif
cursor(1, 1)
normal! zt
redraw!
if screenpos(win_getid(), bottom_line, 1).row > 0
    && getwininfo(win_getid())[0].botline < bottom_line
  targets = simplemotion#FindTargets('ab', false)
  assert_equal([[bottom_line, 1]],
    mapnew(targets, (_, target) => [target.lnum, target.col]),
    'partially displayed bottom line was omitted from visible lines')
  var partial_lines = simplemotion#LineTargets('down')
  assert_true(index(mapnew(partial_lines, (_, target) => target.lnum), bottom_line) >= 0,
    'line motion omitted the partially displayed bottom line')
endif

setlocal nowrap

# Line motions still jump to the first nonblank byte, but draw their hint at a
# visible anchor when that byte is left of a horizontal scroll.
setline(1, [repeat('x', 200), repeat('y', 200), repeat('z', 200)])
if line('$') > 3
  deletebufline('%', 4, line('$'))
endif
cursor(1, 150)
winrestview({lnum: 1, col: 150, topline: 1, leftcol: 120})
redraw!
var line_targets = simplemotion#LineTargets('down')
assert_equal(2, len(line_targets))
for target in line_targets
  assert_equal(1, target.col)
  var anchor = screenpos(target.winid, target.lnum, target.hint_col)
  assert_true(anchor.row > 0 && anchor.col > 0,
    'line target hint anchor is not visible')
endfor

# If the left edge cuts through a Tab, virtcol2col() points at the hidden Tab;
# the first following character is the usable hint anchor.
setlocal tabstop=8
setline(1, ['current', "x\tabc"])
if line('$') > 2
  deletebufline('%', 3, line('$'))
endif
cursor(1, 7)
winrestview({lnum: 1, col: 7, topline: 1, leftcol: 4})
redraw!
line_targets = simplemotion#LineTargets('down')
assert_equal(1, len(line_targets), 'a partially visible Tab row lost its line target')
assert_equal(1, line_targets[0].col)
assert_equal(3, line_targets[0].hint_col)
var tab_anchor = screenpos(line_targets[0].winid, 2, line_targets[0].hint_col)
assert_true(tab_anchor.row > 0 && tab_anchor.col > 0)

# A buffer whose file lives on another host — SimpleRemote's remote:// buffers
# and anything else served by autocommands — is a document like any other, and
# hints must land in it.
new
setline(1, ['ab remote one', 'ab remote two'])
setlocal buftype=acwrite
winrestview({lnum: 1, col: 1, topline: 1, leftcol: 0})
redraw!
targets = simplemotion#FindTargets('ab', false)
assert_equal([[1, 1], [2, 1]],
  mapnew(targets, (_, target) => [target.lnum, target.col]),
  'hints do not reach an acwrite buffer')
setlocal buftype=nofile
assert_equal([], simplemotion#FindTargets('ab', false),
  'hints must still skip scratch buffers')
bwipeout!

assert_equal(2, exists(':SimpleMotion'))
assert_match('simplemotion', maparg('<Plug>(simplemotion-overwin-f2)', 'n'))
assert_true(exists('#SimpleMotion#ColorScheme'),
  'no ColorScheme autocmd restores SimpleMotionLabel')

new
setlocal buftype= wrap
setline(1, ['current', '   ', '', 'target'])
cursor(1, 1)
redraw!
set nomagic
var nonblank_targets = simplemotion#LineTargets('down')
assert_equal([4], mapnew(nonblank_targets, (_, target) => target.lnum),
  'nomagic must not turn blank lines into jump targets')
set magic
bwipeout!

if !empty(v:errors)
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
endif
qa!
