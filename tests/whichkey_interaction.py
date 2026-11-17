#!/usr/bin/env python3
"""Real PTY keys; timer RPC barriers observe actual popup/getcharstr waits.

SIMPLEWHICHKEY_ROOT must point at a checkout (no implicit network downloads).
Each test uses a fresh Vim, while each scenario exercises both plugins together.
"""
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
WK = Path(os.environ.get('SIMPLEWHICHKEY_ROOT', ROOT.parent / 'simplewhichkey')).resolve()
VIM = os.environ.get('VIM', 'vim')


class Session:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='motion-whichkey-')
        self.request = Path(self.tmp.name) / 'request.json'
        self.reply = Path(self.tmp.name) / 'reply.json'
        self.counter = 0
        self.output = bytearray()
        self.master, slave = pty.openpty()
        env = dict(os.environ, TERM='xterm', SIMPLEMOTION_ROOT=str(ROOT),
                   SIMPLEWHICHKEY_ROOT=str(WK), CROSS_REQUEST=str(self.request),
                   CROSS_REPLY=str(self.reply))
        self.proc = subprocess.Popen(
            [VIM, '-Nu', 'NONE', '-n', '-i', 'NONE', '-S',
             str(ROOT / 'tests/whichkey_driver.vim')],
            stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)

    def drain(self):
        if select.select([self.master], [], [], 0.01)[0]:
            try:
                self.output.extend(os.read(self.master, 65536))
            except OSError:
                pass

    def rpc(self, action='state'):
        self.counter += 1
        pending = self.request.with_suffix('.tmp')
        pending.write_text(json.dumps(dict(id=self.counter, action=action)))
        pending.replace(self.request)
        end = time.monotonic() + 5
        while time.monotonic() < end:
            self.drain()
            try:
                state = json.loads(self.reply.read_text())
            except FileNotFoundError:
                state = {}
            if state.get('id') == self.counter:
                assert not state['failure'], state
                assert not state['errors'], state
                assert not state['errmsg'], state
                return state
            if self.proc.poll() is not None:
                break
        raise AssertionError(f'RPC {action} timed out\n{self.output.decode(errors="replace")}')

    def wait(self, predicate):
        end = time.monotonic() + 5
        state = None
        while time.monotonic() < end:
            state = self.rpc()
            if predicate(state):
                return state
        raise AssertionError(f'State did not settle: {state}\n{self.output.decode(errors="replace")}')

    def keys(self, keys):
        os.write(self.master, keys.encode())

    def whichkey(self):
        self.keys('z')
        return self.wait(lambda s: s['panels'] == ['SimpleWhichKeyNormal'])

    def motion(self):
        self.whichkey()
        self.keys('x')
        return self.wait(lambda s: len(s['panels']) == 3
                         and set(s['panels']) == {'SimpleMotionLabel'})

    def idle(self):
        return self.wait(lambda s: not s['panels'] and 'simplewhichkey#Start' in s['hook'])

    def close(self):
        if self.master is None:
            return
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        os.close(self.master)
        self.master = None
        self.tmp.cleanup()


class Interaction(unittest.TestCase):
    def setUp(self):
        self.assertTrue((WK / 'plugin/simplewhichkey.vim').is_file(),
                        'Set SIMPLEWHICHKEY_ROOT to a SimpleWhichKey checkout')
        self.s = Session()
        self.addCleanup(self.s.close)
        self.s.rpc()

    def recovery(self):
        before = self.s.whichkey()['hit']
        self.s.keys('y')
        return self.s.wait(lambda s: not s['panels'] and s['hit'] == before + 1)

    def test_normal_handoff_and_hook_restore(self):
        for _ in range(3):
            self.s.rpc('reset_cursor')
            shown = self.s.motion()
            self.assertEqual(shown['original'], shown['buf'])
            self.s.keys('a')
            state = self.s.idle()
            self.assertEqual(2, state['line'])
            self.recovery()

    def test_whichkey_context_changes_do_not_start_motion(self):
        # Each subcase starts a new editor, but always with BOTH plugins loaded.
        for action in ['switch', 'edit', 'autocmd_edit', 'replace', 'close', 'close_reopen']:
            with self.subTest(action=action):
                if action != 'switch':
                    self.s.close()
                    self.s = Session()
                    self.addCleanup(self.s.close)
                    self.s.rpc()
                self.s.whichkey()
                changed = self.s.rpc(action)
                self.s.keys('x')
                state = self.s.idle()
                self.assertEqual((changed['win'], changed['buf'], changed['line']),
                                 (state['win'], state['buf'], state['line']))
                self.assertEqual(changed['text'], state['text'])
                self.recovery()

    def test_motion_stale_labels_after_handoff(self):
        for action in ['edit', 'autocmd_edit', 'replace', 'close', 'close_reopen']:
            with self.subTest(action=action):
                if action != 'edit':
                    self.s.close()
                    self.s = Session()
                    self.addCleanup(self.s.close)
                    self.s.rpc()
                self.s.motion()
                changed = self.s.rpc(action)
                self.s.keys('a')
                state = self.s.idle()
                self.assertEqual((changed['win'], changed['buf'], changed['line']),
                                 (state['win'], state['buf'], state['line']))
                self.assertEqual(changed['text'], state['text'])
                self.recovery()

    def test_motion_window_switch_preserves_valid_target(self):
        shown = self.s.motion()
        self.s.rpc('switch')
        self.s.keys('a')
        state = self.s.idle()
        # Motion intentionally jumps across windows; target identity is its guard.
        self.assertEqual(shown['origin'], state['win'])
        self.assertEqual(2, state['line'])
        self.recovery()

    def test_context_change_during_search_needle(self):
        for phase in ['first', 'second']:
            for action in ['switch', 'edit', 'autocmd_edit', 'replace', 'close', 'close_reopen']:
                with self.subTest(phase=phase, action=action):
                    self.s.close()
                    self.s = Session()
                    self.addCleanup(self.s.close)
                    self.s.rpc()
                    self.s.whichkey()
                    self.s.keys('f')
                    self.s.wait(lambda s: not s['panels'] and not s['hook']
                                and s['queued'] == 0)
                    if phase == 'second':
                        self.s.keys('z')
                        self.s.wait(lambda s: s['queued'] == 0)
                    changed = self.s.rpc(action)
                    self.s.keys('z')
                    state = self.s.idle()
                    self.assertEqual((changed['win'], changed['buf'], changed['line']),
                                     (state['win'], state['buf'], state['line']))
                    self.assertEqual(changed['text'], state['text'])
                    self.recovery()

    def test_burst_choice_keeps_search_arguments_in_order(self):
        self.s.whichkey()
        # A single PTY write leaves the search arguments queued behind the choice.
        self.s.keys('fzz')
        self.s.wait(lambda s: s['panels'] == ['SimpleMotionLabel'] * 2)
        self.s.keys('a')
        state = self.s.idle()
        self.assertEqual(state['origin'], state['win'])
        self.assertEqual(2, state['line'])
        self.recovery()

    def test_winenter_edit_after_whichkey_search(self):
        self.s.rpc('search_setup')
        self.s.whichkey()
        self.s.keys('fzz')
        self.s.wait(lambda s: s['panels'] == ['SimpleMotionLabel'] * 2)
        self.s.keys('a')
        state = self.s.idle()
        self.assertEqual(state['origin'], state['win'])
        self.assertEqual(4, state['line'])
        self.assertEqual('changed on entry', state['text'][1])
        self.recovery()

    def test_cancel_focus_event_and_external_popup_close(self):
        for action in ['state', 'focuslost', 'close_popups']:
            with self.subTest(action=action):
                before = self.s.whichkey()
                self.s.rpc(action)
                self.s.keys('\x1b')
                self.s.idle()
                self.recovery()
                self.s.motion()
                self.s.rpc(action)
                self.s.keys('\x1b')
                after = self.s.idle()
                self.assertEqual(before['line'], after['line'])
                self.recovery()


if __name__ == '__main__':
    if not shutil.which(VIM):
        raise SystemExit(f'Vim executable not found: {VIM}')
    unittest.main(verbosity=2)
