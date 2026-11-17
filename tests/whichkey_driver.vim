vim9script
# Test-only RPC runs on Vim's timer queue, including inside getcharstr().
set nocompatible nomore hidden noswapfile
set lines=30 columns=100 timeoutlen=100 ttimeoutlen=20
execute 'set runtimepath^=' .. fnameescape($SIMPLEMOTION_ROOT)
execute 'set runtimepath^=' .. fnameescape($SIMPLEWHICHKEY_ROOT)
g:simplewhichkey_delay = 20
g:simplewhichkey_prefixes = {n: ['z']}
g:hit = 0
nmap zx <Plug>(simplemotion-down)
nmap zf <Plug>(simplemotion-overwin-f2)
nnoremap zy <Cmd>let g:hit += 1<CR>
execute 'source ' .. fnameescape($SIMPLEMOTION_ROOT .. '/plugin/simplemotion.vim')
execute 'source ' .. fnameescape($SIMPLEWHICHKEY_ROOT .. '/plugin/simplewhichkey.vim')
setline(1, ['origin', 'zz one', 'zz two', 'last'])
var origin = win_getid()
var original = bufnr()
vnew
setline(1, ['survivor', 'other one', 'other two', 'last'])
var survivor = win_getid()
win_gotoid(origin)
cursor(1, 1)
var last_id = -1
var enter_edit = false

def EditOnEnter()
  if enter_edit && win_getid() == origin
    setline(2, 'changed on entry')
  endif
enddef
augroup CrossPluginTest
  autocmd!
  autocmd WinEnter * EditOnEnter()
  autocmd User CrossPluginEdit call setline(2, 'changed by autocmd')
augroup END

def Tick(_: number)
  if !filereadable($CROSS_REQUEST)
    return
  endif
  var req = json_decode(join(readfile($CROSS_REQUEST), '\n'))
  if req.id == last_id
    return
  endif
  last_id = req.id
  var failure = ''
  try
    if req.action ==# 'reset_cursor'
      cursor(1, 1)
    elseif req.action ==# 'switch'
      win_gotoid(survivor)
    elseif req.action ==# 'edit'
      setline(2, 'changed by timer')
    elseif req.action ==# 'autocmd_edit'
      doautocmd User CrossPluginEdit
    elseif req.action ==# 'replace'
      enew
      setline(1, ['replacement', 'zz replacement', 'zz other', 'last'])
      cursor(4, 1)
    elseif req.action ==# 'close' || req.action ==# 'close_reopen'
      win_execute(origin, 'close!')
      if req.action ==# 'close_reopen'
        execute 'sbuffer ' .. original
      endif
      cursor(4, 1)
    elseif req.action ==# 'focuslost'
      doautocmd FocusLost
    elseif req.action ==# 'close_popups'
      for id in popup_list()
        popup_close(id)
      endfor
    elseif req.action ==# 'search_setup'
      cursor(4, 1)
      win_gotoid(survivor)
      enter_edit = true
    elseif req.action ==# 'quit'
      qa!
    elseif req.action !=# 'state'
      throw 'Unknown action: ' .. req.action
    endif
  catch
    failure = v:exception .. ' at ' .. v:throwpoint
  endtry
  var panels: list<string> = []
  for id in popup_list()
    add(panels, get(popup_getoptions(id), 'highlight', ''))
  endfor
  var reply = {
    id: req.id, failure: failure, errors: v:errors, errmsg: v:errmsg,
    panels: panels, win: win_getid(), buf: bufnr(), line: line('.'),
    text: getline(1, '$'), origin: origin, original: original,
    survivor: survivor, hit: g:hit, mode: mode(1), queued: getchar(1),
    hook: get(maparg('z', 'n', false, true), 'rhs', ''),
  }
  writefile([json_encode(reply)], $CROSS_REPLY .. '.tmp')
  rename($CROSS_REPLY .. '.tmp', $CROSS_REPLY)
enddef

timer_start(10, Tick, {repeat: -1})
