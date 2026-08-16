vim9script

set nocompatible nomore
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

for count in [1, 2, 26, 27, 200]
  var labels = simplemotion#LabelCodes(count)
  assert_equal(count, len(labels))
  assert_equal(count, len(uniq(sort(copy(labels)))))
endfor

# A buffer whose file lives on another host — SimpleRemote's remote:// buffers
# and anything else served by autocommands — is a document like any other, and
# hints must land in it.
new
setline(1, ['ab remote one', 'ab remote two'])
setlocal buftype=acwrite
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

if !empty(v:errors)
  writefile(v:errors, ROOT .. '/tests/errors.log')
  cquit
endif
qa!
