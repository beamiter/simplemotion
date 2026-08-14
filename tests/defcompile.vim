set nocompatible
set nomore
let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set runtimepath^=' .. fnameescape(s:root)
execute 'source ' .. fnameescape(s:root .. '/plugin/simplemotion.vim')
execute 'source ' .. fnameescape(s:root .. '/autoload/simplemotion.vim')
defcompile
qall!
