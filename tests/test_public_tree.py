"""scripts/check_public_tree.py --default-branch against temporary local Git repositories.

The "remote" is a folder on disk, so nothing goes online. Git is isolated from the
user's configuration.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GIT = shutil.which('git')
HANDOUT = ('docs/ios.md', 'docs/worker.md', 'ios/scripts/configure.py', 'ios/scripts/check.py', 'bin/capture')


@unittest.skipUnless(GIT, 'git is required')
class DefaultBranchTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        tmp = Path(self._tmp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Fictional', GIT_AUTHOR_EMAIL='fictional@fictional.test',
                        GIT_COMMITTER_NAME='Fictional', GIT_COMMITTER_EMAIL='fictional@fictional.test')
        self.remote, self.clone = tmp / 'remote', tmp / 'clone'
        self.remote.mkdir()
        self.git(self.remote, 'init', '-q', '-b', 'main')
        (self.remote / 'README.md').write_text('Fictional project.\n')
        self.commit('readme')
        self.git(tmp, 'clone', '-q', str(self.remote), str(self.clone))
        (self.clone / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/check_public_tree.py', self.clone / 'scripts/check_public_tree.py')

    def tearDown(self):
        self._tmp.cleanup()

    def git(self, cwd, *args):
        return subprocess.run([GIT, *args], cwd=cwd, env=self.env, capture_output=True, text=True, check=True)

    def commit(self, message):
        self.git(self.remote, 'add', '-A')
        self.git(self.remote, 'commit', '-q', '-m', message)

    def check(self, *args):
        return subprocess.run([sys.executable, str(self.clone / 'scripts/check_public_tree.py'), *args],
                              cwd=self.clone, env=self.env, capture_output=True, text=True)

    def test_default_branch_without_the_guides_fails_and_names_them(self):
        result = self.check('--default-branch')
        self.assertEqual(result.returncode, 1)
        for name in HANDOUT:
            self.assertIn(f'origin/main (as last fetched) has no {name}', result.stderr)
        self.assertEqual(self.check().returncode, 0, 'without the flag only the files are checked')

    def test_passes_once_the_guides_are_on_the_default_branch_and_fetched(self):
        for name in HANDOUT:
            (self.remote / name).parent.mkdir(parents=True, exist_ok=True)
            (self.remote / name).write_text('Fictional.\n')
        self.commit('guides')
        self.assertEqual(self.check('--default-branch').returncode, 1, 'not fetched yet')
        self.git(self.clone, 'fetch', '-q', 'origin')
        result = self.check('--default-branch')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('The default branch has the setup guides', result.stdout)

    def test_unknown_origin_head_says_how_to_set_it(self):
        self.git(self.clone, 'remote', 'set-head', 'origin', '--delete')
        result = self.check('--default-branch')
        self.assertEqual(result.returncode, 1)
        self.assertIn('git remote set-head origin --auto', result.stderr)


if __name__ == '__main__':
    unittest.main()
