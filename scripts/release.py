#!/usr/bin/env python3
"""Archive committed files only; never execute the tag's code or overwrite assets."""
from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import zipfile

REPO = 'risense-ai/respire-qoder'
TAG_RE = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z')
SHA_RE = re.compile(r'[0-9a-f]{40}\Z')


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def validate_identity(tag: str, sha: str) -> None:
    if not TAG_RE.fullmatch(tag) or not SHA_RE.fullmatch(sha):
        raise ValueError('Require vMAJOR.MINOR.PATCH and an exact lowercase commit SHA')


def verify_zip(data: bytes, tag: str, sha: str) -> None:
    validate_identity(tag, sha)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        if archive.comment.decode() != sha:
            raise ValueError('ZIP commit comment does not match source SHA')
        # ZipInfo.filename is normalized by the host OS, including on read.
        # Check the original central-directory names so Windows cannot hide an
        # unsafe backslash member from the same rejection policy used on POSIX.
        names = [member.orig_filename for member in archive.infolist()]
        if len(names) != len(set(names)):
            raise ValueError('Duplicate ZIP members')
        for name in names:
            if name.startswith('/') or '\\' in name or '..' in name.split('/'):
                raise ValueError('Unsafe ZIP member')
            if '__pycache__' in name.split('/') or name.endswith(('.pyc', '/hook.log')):
                raise ValueError('Runtime/development state in package')
        manifest = json.loads(archive.read('.qoder-plugin/plugin.json'))
        if manifest.get('name') != 'respire-qoder' or manifest.get('version') != tag[1:]:
            raise ValueError('Tag does not match plugin manifest')
        hook = archive.read('hooks/respire.py').decode()
        if not re.search(r'^VERSION = "' + re.escape(tag[1:]) + r'"$', hook, re.M):
            raise ValueError('Tag does not match hook VERSION')
        for required in ('hooks/hooks.json', 'LICENSE', 'README.md', 'skills/respire/SKILL.md'):
            archive.read(required)


def resolve_source() -> tuple[str, str, bool]:
    event, ref = os.environ.get('GITHUB_EVENT_NAME'), os.environ.get('GITHUB_REF', '')
    publish = event == 'workflow_dispatch' or (event == 'push' and ref.startswith('refs/tags/'))
    if not publish:
        sha = command('git', 'rev-parse', 'HEAD')
        manifest = json.loads(command('git', 'show', f'{sha}:.qoder-plugin/plugin.json'))
        tag = 'v' + manifest['version']
        validate_identity(tag, sha)
        return tag, sha, False
    if os.environ.get('GITHUB_REPOSITORY') != REPO:
        raise ValueError('Publishing is restricted to the canonical repository')
    if event == 'workflow_dispatch':
        if ref != 'refs/heads/main':
            raise ValueError('Recovery must run the workflow from main')
        tag, expected = os.environ.get('RELEASE_TAG', ''), os.environ.get('EXPECTED_SHA', '')
    else:
        tag = ref.removeprefix('refs/tags/')
        expected = command('git', 'rev-parse', os.environ['GITHUB_SHA'] + '^{commit}')
    validate_identity(tag, expected)
    # Fetch the existing remote tag, never create/move it or check out its code.
    command('git', 'fetch', '--no-tags', 'origin', 'refs/tags/' + tag)
    sha = command('git', 'rev-parse', 'FETCH_HEAD^{commit}')
    if sha != expected:
        raise ValueError('Remote tag changed or does not match expected SHA')
    command('git', 'fetch', '--no-tags', 'origin', 'refs/heads/main')
    subprocess.run(['git', 'merge-base', '--is-ancestor', sha, 'FETCH_HEAD'], check=True)
    return tag, sha, True


def prepare() -> None:
    tag, sha, publish = resolve_source()
    out = Path('release-out')
    out.mkdir(exist_ok=False)
    filename = f'respire-qoder-{tag[1:]}.zip'
    data = subprocess.check_output(['git', 'archive', '--format=zip', sha])
    verify_zip(data, tag, sha)
    (out / filename).write_bytes(data)
    digest = hashlib.sha256(data).hexdigest()
    (out / 'SHA256SUMS').write_text(f'{digest}  {filename}\n')
    (out / 'release.json').write_text(json.dumps({'tag': tag, 'sha': sha, 'filename': filename}) + '\n')
    notes = f'''respire-qoder {tag[1:]}

Source commit: {sha}

The ZIP contains only committed files from this exact tag/commit; its comment records the SHA. Recovery never packages the current main in place of an older tag.

Install: extract the ZIP and use `qoder plugins install <absolute plugin directory>`, or import it in Qoder Desktop. The engine is installed separately with `npm i -g rsrs-cli@latest`.

Verification: CI runs package validation and isolated credential-guard tests with temporary stub engines, including a required normal-input positive control and a dead-stub negative control. No real rsrs engine, user database or host installation is used. CI tests the workflow revision; recovery packages an existing tag without executing that tag's code.

The original 0.6.8 source received independent Linux isolation verification: 15 PASS / 0 FAIL, plus a dead-stub control returning 12 failures and exit 1. Windows .cmd, macOS and the real host were not independently exercised in that original audit. The full legacy test_hooks.sh suite was not run; its author-reported eight baseline failures were not independently reproduced. The new isolated CI entry does not establish real-host acceptance or full legacy-suite success. Credential detection remains heuristic.

sha256 {digest}
'''
    (out / 'notes.md').write_text(notes)
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
            output.write(f'tag={tag}\nsha={sha}\npublish={str(publish).lower()}\n')
    print(f'Verified {filename}: {sha}, sha256 {digest}, publish={publish}')


def asset_plan(release: dict, expected: dict[str, str], sha: str) -> list[str]:
    if f'Source commit: {sha}' not in (release.get('body') or ''):
        raise ValueError('Existing release has a different/unknown source; refusing to modify it')
    present = set()
    for asset in release.get('assets', []):
        name = asset['name']
        if name not in expected or name in present or asset.get('digest') != 'sha256:' + expected[name]:
            raise ValueError('Existing asset differs or is unexpected; never overwrite it')
        present.add(name)
    return [name for name in expected if name not in present]


def matching_releases(tag: str) -> list[dict]:
    matches, page = [], 1
    while True:
        releases = json.loads(command('gh', 'api', f'repos/{REPO}/releases?per_page=100&page={page}'))
        matches.extend(r for r in releases if r['tag_name'] == tag)
        if len(releases) < 100:
            return matches
        page += 1


def publish() -> None:
    if os.environ.get('GITHUB_REPOSITORY') != REPO:
        raise ValueError('Wrong publishing repository')
    event, ref = os.environ.get('GITHUB_EVENT_NAME'), os.environ.get('GITHUB_REF', '')
    if not ((event == 'push' and ref.startswith('refs/tags/v')) or
            (event == 'workflow_dispatch' and ref == 'refs/heads/main')):
        raise ValueError('Publishing is forbidden for this event/ref')
    out = Path('release-out')
    meta = json.loads((out / 'release.json').read_text())
    tag, sha = os.environ['RELEASE_TAG'], os.environ['EXPECTED_SHA']
    validate_identity(tag, sha)
    filename = f'respire-qoder-{tag[1:]}.zip'
    if meta != {'tag': tag, 'sha': sha, 'filename': filename}:
        raise ValueError('Artifact does not match the selected source')
    data = (out / filename).read_bytes()
    verify_zip(data, tag, sha)
    digest = hashlib.sha256(data).hexdigest()
    if (out / 'SHA256SUMS').read_text() != f'{digest}  {filename}\n':
        raise ValueError('Artifact checksum mismatch')
    remote = json.loads(command('gh', 'api', f'repos/{REPO}/git/ref/tags/{tag}'))['object']
    if remote['type'] == 'tag':
        remote = json.loads(command('gh', 'api', f'repos/{REPO}/git/tags/' + remote['sha']))['object']
    if remote.get('type') != 'commit' or remote.get('sha') != sha:
        raise ValueError('Remote tag no longer matches the selected commit')
    expected = {name: hashlib.sha256((out / name).read_bytes()).hexdigest()
                for name in (filename, 'SHA256SUMS')}
    # List includes drafts; only resume releases created with this exact source marker.
    matches = matching_releases(tag)
    if len(matches) > 1:
        raise ValueError('Multiple releases for this tag')
    if not matches:
        subprocess.run(['gh', 'release', 'create', tag, '--repo', REPO, '--verify-tag', '--draft',
                        '--title', f'respire-qoder {tag[1:]}', '--notes-file', str(out / 'notes.md')], check=True)
        matches = matching_releases(tag)
        if len(matches) != 1:
            raise ValueError('Cannot identify newly created draft')
    release = matches[0]
    for name in asset_plan(release, expected, sha):
        subprocess.run(['gh', 'release', 'upload', tag, str(out / name), '--repo', REPO], check=True)
    updated = json.loads(command('gh', 'api', f'repos/{REPO}/releases/' + str(release['id'])))
    if asset_plan(updated, expected, sha):
        raise ValueError('Assets missing after upload')
    if updated['draft']:
        subprocess.run(['gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false'], check=True)
    print(f'Published/verified {tag} from {sha}; existing assets were never replaced')


if __name__ == '__main__':
    {'prepare': prepare, 'publish': publish}[sys.argv[1]]()
