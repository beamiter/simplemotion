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

def AddMatches(targets: list<dict<any>>, winid: number, bufnr: number,
    first: number, last: number, pattern: string)
  var maximum = get(g:, 'simplemotion_max_targets', 500)
  for lnum in range(first, last)
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
    AddMatches(targets, info.winid, info.bufnr, info.topline, info.botline, pattern)
    if len(targets) >= get(g:, 'simplemotion_max_targets', 500)
      break
    endif
  endfor
  return targets
enddef

def LineTargets(direction: string): list<dict<any>>
  var info = getwininfo(win_getid())[0]
  var current = line('.')
  var first = direction ==# 'down' ? current + 1 : info.topline
  var last = direction ==# 'down' ? info.botline : current - 1
  var targets: list<dict<any>> = []
  if first > last
    return targets
  endif
  for lnum in range(first, last)
    var text = getline(lnum)
    if text =~# '^\s*$'
      continue
    endif
    add(targets, {
      winid: win_getid(),
      bufnr: bufnr(),
      lnum: lnum,
      col: match(text, '\S') + 1,
    })
  endfor
  if direction ==# 'up'
    reverse(targets)
  endif
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
  for index in range(len(targets))
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
