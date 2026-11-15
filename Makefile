.PHONY: check defcompile test test-folds test-lifecycle

check: defcompile test test-folds test-lifecycle

defcompile:
	vim -N -u NONE -n -i NONE -es -S tests/defcompile.vim

test:
	vim -N -u NONE -n -i NONE -es -S tests/vim_smoke.vim

# Needs a 20000-line buffer folded down to a handful of rows, which the smoke
# test's four-line fixture cannot provide: on a buffer that never folds, every
# assertion about staying inside the viewport passes without testing anything.
test-folds:
	vim -N -u NONE -n -i NONE -es -S tests/vim_folds.vim

# A real terminal keeps getcharstr() alive while timers change the target.
test-lifecycle:
	python3 tests/jump_lifecycle.py
