vim9script

if exists('g:loaded_simplemotion')
  finish
endif
g:loaded_simplemotion = 1

if v:version < 901 || !has('popupwin')
  echohl WarningMsg
  echomsg '[SimpleMotion] Vim 9.1 with +popupwin is required.'
  echohl None
  finish
endif

g:simplemotion_keys = get(g:, 'simplemotion_keys', 'asdfghjklqwertyuiopzxcvbnm')
g:simplemotion_smartcase = get(g:, 'simplemotion_smartcase', 1)
g:simplemotion_max_targets = get(g:, 'simplemotion_max_targets', 500)

command! SimpleMotion simplemotion#Jump('f2')
command! SimpleMotionDown simplemotion#Jump('down')
command! SimpleMotionUp simplemotion#Jump('up')
command! SimpleMotionHealth simplemotion#Health()

nnoremap <silent> <Plug>(simplemotion-overwin-f2) <ScriptCmd>simplemotion#Jump('f2')<CR>
nnoremap <silent> <Plug>(simplemotion-down) <ScriptCmd>simplemotion#Jump('down')<CR>
nnoremap <silent> <Plug>(simplemotion-up) <ScriptCmd>simplemotion#Jump('up')<CR>

highlight default SimpleMotionLabel cterm=bold ctermfg=Black ctermbg=Yellow gui=bold guifg=#282828 guibg=#ffcc66
