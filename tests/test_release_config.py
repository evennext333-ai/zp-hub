import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build
import publish

ROOT = Path(__file__).resolve().parents[1]


class ReleaseConfigTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (ROOT / '.github/workflows/publish-hub.yml').read_text()
        self.job = self.workflow.split('\n  publish:\n', 1)[1]
        self.script = textwrap.dedent(self.job.split('        run: |\n', 1)[1])

    def test_same_repository_token_permissions_and_existing_tag(self):
        self.assertIn("if: github.repository == 'evennext333-ai/zs-hub'", self.job)
        self.assertIn('GH_REPO: evennext333-ai/zs-hub', self.job)
        self.assertIn('GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}', self.job)
        self.assertIn('contents: write', self.job)
        self.assertEqual(self.workflow.count('contents: write'), 1)
        self.assertIn('permissions:\n  contents: read', self.workflow)
        self.assertIn('ref: refs/tags/${{ inputs.tag || github.ref_name }}', self.workflow)
        self.assertNotIn('HUB_RELEASE_TOKEN', self.workflow)
        self.assertNotIn('lvjunling/r-s-zh', self.workflow)
        self.assertNotIn('defaultBranchRef', self.script)
        subprocess.run(['bash', '-n'], input=self.script, text=True, check=True)

    def run_publish(self, root, *, corrupt=False, extra=False, fail_create=False):
        public = root / 'public'
        public.mkdir()
        for name in ('loader.lua', 'NOTICE.txt'):
            (public / name).write_text('fixture-' + name)
        checksums = ''.join(f'{hashlib.sha256((public / name).read_bytes()).hexdigest()}  {name}\n'
                            for name in ('loader.lua', 'NOTICE.txt'))
        (public / 'SHA256SUMS').write_text(checksums)
        if corrupt:
            (public / 'loader.lua').write_text('tampered')
        if extra:
            (public / 'private.lua').write_text('private fixture')
        binary = root / 'bin'
        binary.mkdir()
        gh = binary / 'gh'
        gh.write_text(f'#!{sys.executable}\n' + textwrap.dedent('''\
            import json, os, sys
            with open(os.environ['GH_CALLS'], 'a') as stream:
                stream.write(json.dumps({'repo': os.environ['GH_REPO'], 'args': sys.argv[1:]}) + '\\n')
            if os.environ['FAIL_CREATE'] == '1' and sys.argv[1:3] == ['release', 'create']:
                sys.exit(1)
        '''))
        gh.chmod(0o755)
        calls = root / 'calls.jsonl'
        env = {**os.environ, 'PATH': str(binary) + os.pathsep + os.environ['PATH'],
               'GH_REPO': 'evennext333-ai/zs-hub', 'GH_TOKEN': 'fixture', 'GH_CALLS': str(calls),
               'RELEASE_TAG': 'hub-v1.0.0', 'SOURCE_REPOSITORY': 'evennext333-ai/zs-hub',
               'SOURCE_SHA': 'a' * 40, 'FAIL_CREATE': str(int(fail_create))}
        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', self.script],
                                cwd=root, env=env, capture_output=True, text=True)
        commands = [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []
        return result, commands

    def test_publishes_only_checked_assets_to_the_built_tag_then_marks_latest(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_publish(Path(directory))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([call['repo'] for call in calls], ['evennext333-ai/zs-hub'] * 2)
        args = calls[0]['args']
        self.assertEqual(args[:6], ['release', 'create', 'hub-v1.0.0', 'loader.lua', 'NOTICE.txt', 'SHA256SUMS'])
        self.assertIn('--verify-tag', args)
        self.assertIn('--draft', args)
        self.assertEqual(args[args.index('--target') + 1], 'a' * 40)
        self.assertEqual(calls[1]['args'], ['release', 'edit', 'hub-v1.0.0', '--draft=false', '--latest'])

    def test_invalid_assets_or_failed_creation_never_publish_latest(self):
        for changes in ({'corrupt': True}, {'extra': True}, {'fail_create': True}):
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_publish(Path(directory), **changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call['args'][:2] == ['release', 'edit'] for call in calls))
                if not changes.get('fail_create'):
                    self.assertEqual(calls, [])

    def test_renamed_repository_has_no_stale_github_target_in_publish_sources(self):
        previous = 'evennext333-ai/' + 'zp-hub'
        for name in ('publish.py', 'src/keys.html', '.github/workflows/publish-hub.yml', 'README.md'):
            self.assertNotIn(previous, (ROOT / name).read_text())

    def test_primary_loader_and_api_are_separate_and_consistent(self):
        self.assertEqual(build.DEFAULT_API_URL, 'https://www.zldelf.cloud/api')
        self.assertEqual(publish.LOADER_URL, 'https://github.com/evennext333-ai/zs-hub/releases/latest/download/loader.lua')
        self.assertIn('<title>ZS Hub', (ROOT / 'src/keys.html').read_text())
        self.assertNotIn('ZP HUB', (ROOT / 'src/keys.html').read_text())
        for path in ('README.md', 'src/keys.html'):
            self.assertIn(publish.LOADER_URL, (ROOT / path).read_text())
        self.assertIn(publish.LOADER_URL, self.script)
        self.assertIn('API: https://www.zldelf.cloud/api', self.script)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'public'
            build.build(build.DEFAULT_API_URL, output)
            for path in (ROOT / 'src/keys.html', output / 'keys.html'):
                html = path.read_text()
                self.assertEqual(re.findall(r'href="([^"\s]*loader\.lua)"', html), [publish.LOADER_URL])
                self.assertNotIn('国内备用入口', html)


if __name__ == '__main__':
    unittest.main()
