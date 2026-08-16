vim9script

def ValidKeys(): list<string>
  var seen: dict<bool> = {}
  var keys: list<string> = []
  for key in split(get(g:, 'simplemotion_keys', ''), '\zs')
    if key =~# '^[[:print:]]$' && !has_key(seen, key)
      seen[key] = true
      add(keys, key)
    endif
  endfor
  return len(keys) >= 2 ? keys : split('asdfghjkl', '\zs')
enddef

export def LabelCodes(count: number): list<string>
  if count <= 0
    return []
  endif
  var keys = ValidKeys()
  var base = len(keys)
  var width = 1
  var capacity = base
  while capacity < count
    width += 1
    capacity *= base
  endwhile
  var codes: list<string> = []
  for index in range(count)
    var value = index
    var code = ''
    for _ in range(width)
      code = keys[value % base] .. code
      value = value / base
    endfor
    add(codes, code)
  endfor
  return codes
enddef

def SearchPattern(text: string): string
  var prefix = get(g:, 'simplemotion_smartcase', 1) && text =~# '[A-Z]' ? '\C' : '\c'
  return prefix .. '\V' .. escape(text, '\')
enddef

# What a jump costs is the number of buffer lines the scanners walk and the
# number of popups raised for what they find, and both used to scale with the
# size of the file instead of the size of the viewport.  Timing assertions
# cannot police that -- a loaded machine makes them lie in both directions --
# so the two counts are exported and tests/vim_folds.vim budgets them directly,
# the way simplewhichkey budgets mapping-table sweeps.  They only ever grow;
# a caller takes a reading before and after and subtracts.
var scanned = 0
var hinted = 0

export def Counters(): dict<number>
  return {scanned: scanned, hinted: hinted}
enddef

# foldclosed() and foldclosedend() only ever answer for the window that happens
# to be current, so a window's visible lines have to be collected from inside it.
# Exported so the context win_execute() creates can name it, exactly as
# simpleminimap's window probes are; it is an implementation detail of target
# scanning, not public API.  The answer comes back through a script variable
# because win_execute() runs an Ex command, and a :def function's locals are not
# reachable from one.
var visible_lines: list<number> = []

export def VisibleLinesProbe(first: number, last: number)
  # getwininfo()'s botline counts buffer lines, not screen rows, so one closed
  # fold hiding 19989 lines pushes it 19989 lines past the last row actually on
  # screen: a window displaying 11 rows reported topline=1 botline=19999, and
  # both scanners duly walked all 19999.  A closed fold also draws foldtext() on
  # its single row and never the buffer text beneath it, so nothing in
  # [lnum, foldend] can be matched by eye in the first place.  Stepping over the
  # fold is what keeps the walk proportional to the viewport rather than to the
  # file, and it is what stops hints being offered for invisible text.
  var lnum = first
  while lnum <= last
    scanned += 1
    var foldend = foldclosedend(lnum)
    if foldend > 0
      lnum = foldend + 1
      continue
    endif
    add(visible_lines, lnum)
    lnum += 1
  endwhile
enddef

def VisibleLines(winid: number, first: number, last: number): list<number>
  # Cleared here rather than inside the probe: when win_execute() is handed a
  # window that has gone away the probe never runs at all, and handing back the
  # lines left over from the previous window would scatter hints across a buffer
  # that is not on screen.
  visible_lines = []
  win_execute(winid, printf('call simplemotion#VisibleLinesProbe(%d, %d)', first, last))
  return visible_lines
enddef

def AddMatches(targets: list<dict<any>>, winid: number, bufnr: number,
    lines: list<number>, pattern: string)
  var maximum = get(g:, 'simplemotion_max_targets', 500)
  for lnum in lines
    var text = getbufline(bufnr, lnum)[0]
    var start = 0
    while start <= strlen(text)
      var byte = match(text, pattern, start)
      if byte < 0
        break
      endif
      add(targets, {winid: winid, bufnr: bufnr, lnum: lnum, col: byte + 1})
      if len(targets) >= maximum
        return
      endif
      start = byte + 1
    endwhile
  endfor
enddef

export def FindTargets(text: string, all_windows: bool = true): list<dict<any>>
  if empty(text)
    return []
  endif
  var targets: list<dict<any>> = []
  var pattern = SearchPattern(text)
  var windows = all_windows ? getwininfo() : [getwininfo(win_getid())[0]]
  for info in windows
    if info.tabnr != tabpagenr() || getbufvar(info.bufnr, '&buftype') !=# ''
      continue
    endif
    AddMatches(targets, info.winid, info.bufnr,
      VisibleLines(info.winid, info.topline, info.botline), pattern)
    if len(targets) >= get(g:, 'simplemotion_max_targets', 500)
      break
    endif
  endfor
  return targets
enddef

export def LineTargets(direction: string): list<dict<any>>
  var info = getwininfo(win_getid())[0]
  var current = line('.')
  var down = direction ==# 'down'
  var first = down ? current + 1 : info.topline
  var last = down ? info.botline : current - 1
  var targets: list<dict<any>> = []
  if first > last
    return targets
  endif
  # The cap FindTargets has always applied, which this scanner never did.  On a
  # 20000-line buffer folded down to 11 displayed rows :SimpleMotionDown answered
  # with 19998 targets, 19988 of them on lines hidden inside the closed fold and
  # every one of those resolving to the single screen row the fold occupies; the
  # popups for them took 61 seconds to raise and tear down.  This runs in the
  # current window only, so foldclosed() answers for the right one directly and
  # no win_execute() probe is needed.
  var maximum = get(g:, 'simplemotion_max_targets', 500)
  var winid = win_getid()
  var buf = bufnr()
  # Walk outward from the cursor -- 'down' ascending, 'up' descending -- so the
  # list already comes out nearest-first.  Collecting 'up' ascending and calling
  # reverse() at the end, as this used to, would have let the cap discard the
  # lines closest to the cursor and keep the far ones, which is exactly backwards
  # from what the user is aiming at.
  var lnum = down ? first : last
  while down ? lnum <= last : lnum >= first
    scanned += 1
    var foldstart = foldclosed(lnum)
    if foldstart > 0
      # A closed fold is one screen row no matter how many lines it hides, and
      # this is a line motion, so the fold earns exactly one target.  It is
      # anchored at column 1 because the row shows foldtext(), not the buffer
      # line, so the line's own first non-blank column means nothing there.  A
      # fold starting before `first` is already on or above the row the scan
      # began from and earns none.
      if foldstart >= first
        add(targets, {winid: winid, bufnr: buf, lnum: foldstart, col: 1})
      endif
      lnum = down ? foldclosedend(lnum) + 1 : foldstart - 1
    else
      var text = getline(lnum)
      if text !~# '^\s*$'
        add(targets, {
          winid: winid,
          bufnr: buf,
          lnum: lnum,
          col: match(text, '\S') + 1,
        })
      endif
      lnum = down ? lnum + 1 : lnum - 1
    endif
    if len(targets) >= maximum
      break
    endif
  endwhile
  return targets
enddef

def ReadChar(): string
  var key = getcharstr()
  return key ==# "\<Esc>" || key ==# "\<C-c>" ? '' : key
enddef

def ReadNeedle(): string
  echo 'SimpleMotion: type two characters'
  var first = ReadChar()
  if empty(first)
    echo ''
    return ''
  endif
  var second = ReadChar()
  echo ''
  return empty(second) ? '' : first .. second
enddef

def ShowHints(targets: list<dict<any>>, codes: list<string>): list<number>
  var popups: list<number> = []
  # It is the popup count, not the target count, that decides whether a jump
  # feels instant.  Raising them is roughly linear -- 9 ms for 500 -- but tearing
  # them down is not: measured 0.4 ms to close 100, 8 ms for 500, 197 ms for 2000
  # and 1594 ms for 5000, with the redraw in between going 0.2 ms to 792 ms over
  # the same range.  Both scanners now cap what they hand over, so this second
  # stop should never fire; it is here because this is the loop that pays, and a
  # target past it is no worse off than one screenpos() rejects below -- it keeps
  # its code and stays selectable, it just gets no label drawn for it.
  var maximum = get(g:, 'simplemotion_max_targets', 500)
  for index in range(len(targets))
    if len(popups) >= maximum
      break
    endif
    var target = targets[index]
    var screen = screenpos(target.winid, target.lnum, target.col)
    if get(screen, 'row', 0) <= 0 || get(screen, 'col', 0) <= 0
      continue
    endif
    var popup = popup_create(codes[index], {
      line: screen.row,
      col: screen.col,
      minwidth: strdisplaywidth(codes[index]),
      maxwidth: strdisplaywidth(codes[index]),
      minheight: 1,
      maxheight: 1,
      padding: [0, 0, 0, 0],
      mapping: false,
      wrap: false,
      zindex: 300,
      highlight: 'SimpleMotionLabel',
    })
    hinted += 1
    add(popups, popup)
  endfor
  redraw
  return popups
enddef

def PickCode(codes: list<string>): number
  var prefix = ''
  while true
    var key = ReadChar()
    if empty(key)
      return -1
    endif
    prefix ..= key
    var exact = index(codes, prefix)
    if exact >= 0
      return exact
    endif
    if empty(filter(copy(codes), (_, value) => stridx(value, prefix) == 0))
      return -1
    endif
  endwhile
  return -1
enddef

export def Jump(kind: string)
  var targets: list<dict<any>>
  if kind ==# 'f2'
    var needle = ReadNeedle()
    if empty(needle)
      return
    endif
    targets = FindTargets(needle, true)
  elseif kind ==# 'down' || kind ==# 'up'
    targets = LineTargets(kind)
  else
    return
  endif
  if empty(targets)
    echohl WarningMsg
    echomsg '[SimpleMotion] no visible target'
    echohl None
    return
  endif
  if len(targets) == 1
    win_gotoid(targets[0].winid)
    cursor(targets[0].lnum, targets[0].col)
    return
  endif
  var codes = LabelCodes(len(targets))
  var popups = ShowHints(targets, codes)
  var selected = -1
  try
    selected = PickCode(codes)
  finally
    for popup in popups
      popup_close(popup)
    endfor
    redraw
  endtry
  if selected >= 0 && selected < len(targets)
    win_gotoid(targets[selected].winid)
    cursor(targets[selected].lnum, targets[selected].col)
  endif
enddef

export def Health()
  var keys = ValidKeys()
  echomsg 'SimpleMotion health'
  echomsg $'  popupwin: {has("popupwin") ? "yes" : "no"}'
  echomsg $'  labels: {len(keys)} unique keys'
  echomsg $'  target cap: {get(g:, "simplemotion_max_targets", 500)}'
enddef
