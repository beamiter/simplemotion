vim9script

def ValidKeys(): list<string>
  var configured: any = get(g:, 'simplemotion_keys', '')
  if type(configured) != v:t_string
    configured = ''
  endif
  var seen: dict<bool> = {}
  var keys: list<string> = []
  for key in split(configured, '\zs')
    if key =~# '^[[:print:]]$' && !has_key(seen, key)
      seen[key] = true
      add(keys, key)
    endif
  endfor
  return len(keys) >= 2 ? keys : split('asdfghjkl', '\zs')
enddef

def MaxTargets(): number
  var configured: any = get(g:, 'simplemotion_max_targets', 500)
  return type(configured) == v:t_number ? max([0, configured]) : 500
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
  var configured: any = get(g:, 'simplemotion_smartcase', 1)
  var smartcase = type(configured) == v:t_bool
    ? configured
    : type(configured) == v:t_number ? configured != 0 : true
  var prefix = smartcase && text =~# '[A-Z]' ? '\C' : '\c'
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
var probed = 0

export def Counters(): dict<number>
  return {scanned: scanned, hinted: hinted, probed: probed}
enddef

# foldclosed() and foldclosedend() only ever answer for the window that happens
# to be current, so a window's visible lines have to be collected from inside it.
# Exported so the context win_execute() creates can name it, exactly as
# simpleminimap's window probes are; it is an implementation detail of target
# scanning, not public API.  The answer comes back through a script variable
# because win_execute() runs an Ex command, and a :def function's locals are not
# reachable from one.
var visible_lines: list<number> = []
var visible_skipcol = 0

export def VisibleLinesProbe(first: number, last: number)
  visible_skipcol = get(winsaveview(), 'skipcol', 0)
  # getwininfo()'s botline counts buffer lines, not screen rows, so one closed
  # fold hiding 19989 lines pushes it 19989 lines past the last row actually on
  # screen: a window displaying 11 rows reported topline=1 botline=19999, and
  # both scanners duly walked all 19999.  A closed fold also draws foldtext() on
  # its single row and never the buffer text beneath it, so nothing in
  # [lnum, foldend] can be matched by eye in the first place.  Stepping over the
  # fold is what keeps the walk proportional to the viewport rather than to the
  # file, and it is what stops hints being offered for invisible text.
  var visible_last = last
  if visible_last < line('$')
    probed += 1
    var next_screen = screenpos(win_getid(), visible_last + 1, 1)
    if get(next_screen, 'row', 0) > 0
      visible_last += 1
    endif
  endif
  var lnum = first
  while lnum <= visible_last
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
  visible_skipcol = 0
  win_execute(winid, printf('call simplemotion#VisibleLinesProbe(%d, %d)', first, last))
  return visible_lines
enddef

def AddMatches(targets: list<dict<any>>, winid: number, bufnr: number,
    lines: list<number>, pattern: string, maximum: number)
  var infos = getwininfo(winid)
  if empty(infos)
    return
  endif
  var info = infos[0]
  var nowrap = !getwinvar(winid, '&wrap')
  # Wrapped continuation rows can reclaim the number column when 'cpoptions'
  # contains `n`; use the whole window width as a conservative bound and let
  # screenpos() filter the few over-included cells.  Nowrap has one fixed text
  # area and can use the exact textoff subtraction.
  var text_width = nowrap
    ? max([1, info.width - info.textoff]) : max([1, info.width])
  for lnum in lines
    var text = getbufline(bufnr, lnum)[0]
    var start = 0
    var last_byte_col = strlen(text) + 1
    if !empty(text)
      var viewport_vcol = nowrap
        ? info.leftcol + 1
        : lnum == info.topline ? visible_skipcol + 1 : 1
      # With 'smoothscroll', skipcol is a layout offset rather than an exact
      # buffer virtual column: part of the preceding screen row can remain
      # visible. Include one conservative row before it; screenpos() removes
      # the overreach and the scan stays bounded by the viewport.
      var first_vcol = nowrap ? viewport_vcol
        : max([1, viewport_vcol - info.width - info.textoff])
      var last_vcol = nowrap
        ? first_vcol + text_width - 1
        : viewport_vcol + (info.height + 2) * text_width
      var first_byte_col = virtcol2col(winid, lnum, first_vcol)
      last_byte_col = virtcol2col(winid, lnum, last_vcol)
      if first_byte_col <= 0 || last_byte_col <= 0
        continue
      endif
      start = first_byte_col - 1
    endif
    while start <= strlen(text)
      var byte = match(text, pattern, start)
      if byte < 0 || byte + 1 > last_byte_col
        break
      endif
      # A displayed buffer line is not necessarily a displayed target.  With
      # 'nowrap' and a horizontal scroll, or on a wrapped line whose other
      # screen rows are outside the viewport, screenpos() returns zero for the
      # hidden columns.  Giving those matches codes produced selectable jumps
      # for which no popup was drawn, and enough hidden matches could consume
      # the cap before the first visible one was reached.
      probed += 1
      var screen = screenpos(winid, lnum, byte + 1)
      if get(screen, 'row', 0) > 0 && get(screen, 'col', 0) > 0
        add(targets, {winid: winid, bufnr: bufnr, lnum: lnum, col: byte + 1})
        if len(targets) >= maximum
          return
        endif
      endif
      start = byte + 1
    endwhile
  endfor
enddef

# A window worth putting hints in.  The empty 'buftype' is an ordinary file;
# 'acwrite' is one whose reads and writes are served by autocommands, which is
# how a plugin like SimpleRemote presents a file that lives on another host.
# Its text is a document the user is editing and jumping around it is exactly
# as meaningful as in a local file, so refusing it left the plugin dead in
# such a workspace.  Everything else — the quickfix list, help, terminals,
# scratch panels, and the hint overlay itself — stays excluded.
def JumpableBuffer(buf: number): bool
  var buftype = getbufvar(buf, '&buftype')
  return buftype ==# '' || buftype ==# 'acwrite'
enddef

export def FindTargets(text: string, all_windows: bool = true): list<dict<any>>
  var maximum = MaxTargets()
  if empty(text) || maximum == 0
    return []
  endif
  var targets: list<dict<any>> = []
  var pattern = SearchPattern(text)
  var windows = all_windows ? getwininfo() : [getwininfo(win_getid())[0]]
  for info in windows
    if info.tabnr != tabpagenr() || !JumpableBuffer(info.bufnr)
      continue
    endif
    AddMatches(targets, info.winid, info.bufnr,
      VisibleLines(info.winid, info.topline, info.botline), pattern, maximum)
    if len(targets) >= maximum
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
  var bottom = info.botline
  if bottom < line('$')
    probed += 1
    var next_screen = screenpos(win_getid(), bottom + 1, 1)
    if get(next_screen, 'row', 0) > 0
      bottom += 1
    endif
  endif
  var last = down ? bottom : current - 1
  var targets: list<dict<any>> = []
  var maximum = MaxTargets()
  if first > last || maximum == 0
    return targets
  endif
  # The cap FindTargets has always applied, which this scanner never did.  On a
  # 20000-line buffer folded down to 11 displayed rows :SimpleMotionDown answered
  # with 19998 targets, 19988 of them on lines hidden inside the closed fold and
  # every one of those resolving to the single screen row the fold occupies; the
  # popups for them took 61 seconds to raise and tear down.  This runs in the
  # current window only, so foldclosed() answers for the right one directly and
  # no win_execute() probe is needed.
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
        var jump_col = match(text, '\S') + 1
        var hint_col = jump_col
        probed += 1
        var screen = screenpos(winid, lnum, hint_col)
        if (get(screen, 'row', 0) <= 0 || get(screen, 'col', 0) <= 0)
            && !&l:wrap
          hint_col = virtcol2col(winid, lnum, info.leftcol + 1)
          var last_hint_col = virtcol2col(winid, lnum,
            info.leftcol + max([1, info.width - info.textoff]))
          if hint_col <= 0 || last_hint_col <= 0
            lnum = down ? lnum + 1 : lnum - 1
            continue
          endif
          # leftcol may fall in a Tab that began off-screen. virtcol2col()
          # returns that Tab's byte, whose screenpos is zero, while the next
          # character is visible. Walk at most the visible text slice to find
          # a real anchor; the jump column remains the first nonblank byte.
          while hint_col <= last_hint_col
            probed += 1
            screen = screenpos(winid, lnum, hint_col)
            if get(screen, 'row', 0) > 0 && get(screen, 'col', 0) > 0
              break
            endif
            var char = strcharpart(strpart(text, hint_col - 1), 0, 1, true)
            hint_col += max([1, strlen(char)])
          endwhile
        endif
        if get(screen, 'row', 0) <= 0 || get(screen, 'col', 0) <= 0
          lnum = down ? lnum + 1 : lnum - 1
          continue
        endif
        add(targets, {
          winid: winid,
          bufnr: buf,
          lnum: lnum,
          col: jump_col,
          hint_col: hint_col,
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
  var maximum = MaxTargets()
  for index in range(len(targets))
    if len(popups) >= maximum
      break
    endif
    var target = targets[index]
    probed += 1
    var screen = screenpos(target.winid, target.lnum,
      get(target, 'hint_col', target.col))
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
  echomsg $'  target cap: {MaxTargets()}'
enddef
