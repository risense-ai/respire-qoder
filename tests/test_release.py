"""Offline release-policy tests; all network/gh mutations are excluded."""
import importlib.util
import io
import json
import os
from pathlib import Path
from unittest import mock
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = 'c969187b085f934b1edce27de25117a8591dc661'


def package(version='0.6.8', comment=SHA, extra=None):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        archive.comment = comment.encode()
        archive.writestr('.qoder-plugin/plugin.json', json.dumps({'name':'respire-qoder','version':version}))
        archive.writestr('hooks/respire.py', 'VERSION = "' + version + '"\n')
        for name in ('hooks/hooks.json', 'README.md', 'LICENSE', 'skills/respire/SKILL.md'):
            archive.writestr(name, '{}')
        if extra:
            # ZipInfo's constructor normalizes backslashes on Windows. Set the
            # raw archive name afterwards so this remains a genuinely unsafe
            # fixture on every OS instead of silently becoming a safe path.
            member = zipfile.ZipInfo('fixture')
            member.filename = extra
            archive.writestr(member, '')
    return buffer.getvalue()


class ReleasePolicy(unittest.TestCase):
    def test_valid_exact_archive(self):
        release.verify_zip(package(), 'v0.6.8', SHA)

    def test_wrong_version_or_commit_is_rejected(self):
        for data in (package('0.6.7'), package(comment='a' * 40)):
            with self.assertRaises(ValueError):
                release.verify_zip(data, 'v0.6.8', SHA)

    def test_unsafe_archive_is_rejected(self):
        for name in ('../escape', '/absolute', 'hooks\\escape', 'hooks/hook.log', 'hooks/__pycache__/x'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                release.verify_zip(package(extra=name), 'v0.6.8', SHA)

    def test_input_injection_and_noncanonical_tags_are_rejected(self):
        for tag in ('main', 'v01.6.8', 'v0.6.8;echo bad', 'v0.6.8\nsha=bad'):
            with self.assertRaises(ValueError):
                release.validate_identity(tag, SHA)

    def test_identical_assets_are_idempotent(self):
        existing = {'body': 'Source commit: ' + SHA,
                    'assets': [{'name': 'package.zip', 'digest': 'sha256:abc'}]}
        self.assertEqual(release.asset_plan(existing, {'package.zip':'abc'}, SHA), [])
        self.assertEqual(release.asset_plan(existing, {'package.zip':'abc', 'SHA256SUMS':'def'}, SHA), ['SHA256SUMS'])

    def test_conflicting_or_unknown_assets_never_overwrite(self):
        for existing in (
            {'body': '', 'assets': []},
            {'body': 'Source commit: ' + SHA, 'assets': [{'name':'package.zip','digest':'sha256:wrong'}]},
            {'body': 'Source commit: ' + SHA, 'assets': [{'name':'unexpected','digest':'sha256:abc'}]},
        ):
            with self.assertRaises(ValueError):
                release.asset_plan(existing, {'package.zip':'abc'}, SHA)

    def test_recovery_rejects_nonmain_and_wrong_repository_before_fetch(self):
        for repo, ref in ((release.REPO, 'refs/heads/feature'), ('fork/respire-qoder', 'refs/heads/main')):
            env = {'GITHUB_EVENT_NAME':'workflow_dispatch', 'GITHUB_REF':ref,
                   'GITHUB_REPOSITORY':repo, 'RELEASE_TAG':'v0.6.8', 'EXPECTED_SHA':SHA}
            with mock.patch.dict(os.environ, env, clear=True), mock.patch.object(release, 'command') as command:
                with self.assertRaises(ValueError):
                    release.resolve_source()
                command.assert_not_called()

    def test_pr_cannot_enter_publisher(self):
        with mock.patch.dict(os.environ, {'GITHUB_REPOSITORY':release.REPO,
                                        'GITHUB_EVENT_NAME':'pull_request','GITHUB_REF':'refs/pull/3/merge'}, clear=True):
            with self.assertRaises(ValueError):
                release.publish()

    def test_recovery_fetches_exact_tag_and_rejects_changed_sha(self):
        env = {'GITHUB_REPOSITORY':release.REPO, 'GITHUB_EVENT_NAME':'workflow_dispatch',
               'GITHUB_REF':'refs/heads/main', 'RELEASE_TAG':'v0.6.8', 'EXPECTED_SHA':SHA}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(release, 'command', side_effect=['', 'a' * 40]) as command, \
                mock.patch.object(release.subprocess, 'run') as run:
            with self.assertRaisesRegex(ValueError, 'Remote tag changed'):
                release.resolve_source()
            self.assertEqual(command.call_args_list[0].args,
                             ('git','fetch','--no-tags','origin','refs/tags/v0.6.8'))
            run.assert_not_called()


if __name__ == '__main__':
    unittest.main(verbosity=2)
