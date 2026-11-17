#!/usr/bin/env python3
"""Drive actual getcharstr() waits while Vim timers mutate hint targets."""
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class JumpLifecycle(unittest.TestCase):
    def run_case(self, change, expected_line, expected_buffer=None, setup="", kind="down"):
        with tempfile.TemporaryDirectory(prefix='simplemotion-') as tmp:
            result = Path(tmp) / 'result'
            script = Path(tmp) / 'test.vim'
            script.write_text(f'''vim9script
set nocompatible nomore hidden
execute 'set runtimepath^=' .. fnameescape({str(ROOT)!r})
execute 'source ' .. fnameescape({str(ROOT / 'plugin/simplemotion.vim')!r})
set lines=30 columns=100
setline(1, ['origin', 'target one', 'target two', 'last'])
cursor(1, 1)
{setup}
redraw!
def Mutate(_timer: number)
{change}
  feedkeys('a', 'nt')
enddef
timer_start(80, Mutate)
simplemotion#Jump({kind!r})
assert_equal({expected_line}, line('.'))
{("assert_equal(" + repr(expected_buffer) + ", getline(1))") if expected_buffer else ''}
assert_equal([], popup_list())
writefile(empty(v:errors) ? ['OK'] : v:errors, {str(result)!r})
qa!
''')
            master, slave = pty.openpty()
            env = dict(os.environ, TERM='xterm')
            proc = subprocess.Popen(
                ['vim', '-Nu', 'NONE', '-n', '-i', 'NONE', '-S', str(script)],
                stdin=slave, stdout=slave, stderr=slave, env=env)
            os.close(slave)
            output = bytearray()
            deadline = time.monotonic() + 10
            try:
                while proc.poll() is None and time.monotonic() < deadline:
                    if select.select([master], [], [], 0.1)[0]:
                        try:
                            output.extend(os.read(master, 65536))
                        except OSError:
                            break
                if proc.poll() is None:
                    proc.wait(timeout=1)
                self.assertEqual(proc.returncode, 0, output.decode(errors='replace'))
                self.assertTrue(result.exists(), output.decode(errors='replace'))
                self.assertEqual(result.read_text(), 'OK\n')
            finally:
                if proc.poll() is None:
                    proc.kill()
                proc.wait()
                os.close(master)

    def test_replaced_buffer_during_needle_cancels(self):
        self.run_case(
            "  enew\n  setline(1, ['replacement', 'za match', 'last'])\n  cursor(3, 1)",
            3, 'replacement', setup="feedkeys('z', 'nt')", kind='f2')

    def test_unchanged_target_jumps(self):
        self.run_case('  # no change', 2)

    def test_changed_text_cancels(self):
        self.run_case("  setline(2, 'different')", 1)

    def test_edit_elsewhere_cancels_conservatively(self):
        self.run_case("  setline(4, 'different')", 1)

    def test_replaced_buffer_cancels(self):
        self.run_case("  enew\n  setline(1, ['replacement', 'two', 'three'])\n  cursor(3, 1)", 3, 'replacement')

    def test_winenter_edit_does_not_apply_old_position(self):
        self.run_case('  # no change', 4, 'origin', setup="""
setline(1, ['origin', 'zz one', 'zz two', 'last'])
cursor(4, 1)
var target_window = win_getid()
vnew
setline(1, ['source'])
def OnEnter()
  if win_getid() == target_window
    setline(2, 'changed on entry')
  endif
enddef
augroup MotionTest
  autocmd WinEnter * OnEnter()
augroup END
feedkeys('zz', 'nt')
""", kind='f2')

    def test_single_target_winenter_edit(self):
        self.run_case('  # no change', 4, 'origin', setup="""
setline(1, ['origin', 'zz one', 'other', 'last'])
cursor(4, 1)
var target_window = win_getid()
vnew
setline(1, ['source'])
def OnEnter()
  if win_getid() == target_window
    setline(2, 'changed on entry')
  endif
enddef
augroup MotionTest
  autocmd WinEnter * OnEnter()
augroup END
feedkeys('zz', 'nt')
""", kind='f2')

    def test_single_target_winenter_close(self):
        self.run_case('  # no change', 3, 'source', setup="""
setline(1, ['origin', 'zz one', 'other', 'last'])
var target_window = win_getid()
vnew
setline(1, ['source', 'two', 'three'])
cursor(3, 1)
def OnEnter()
  if win_getid() == target_window
    close!
  endif
enddef
augroup MotionTest
  autocmd WinEnter * OnEnter()
augroup END
feedkeys('zz', 'nt')
""", kind='f2')

    def test_closed_window_does_not_move_survivor(self):
        self.run_case("  var old = win_getid()\n  vnew\n  setline(1, ['survivor', 'two', 'three'])\n  win_execute(old, 'close!')\n  cursor(3, 1)", 3, 'survivor')


if __name__ == '__main__':
    unittest.main()
