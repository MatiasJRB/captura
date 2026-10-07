#!/usr/bin/env python3
"""Small publication safety net, not a secret-scanning or legal-audit guarantee.

With --default-branch it also checks, offline, that the default branch as last fetched
(origin/HEAD) has the setup guides and scripts: the guides tell people to "git clone"
the repository, which checks out that branch. It refuses when origin is not the URL the
guides clone, since a test clone's origin/HEAD says nothing about what people get.
"""
import argparse
from pathlib import Path
import re
import subprocess
import sys
root=Path(__file__).resolve().parents[1]
HANDOUT=('docs/ios.md','docs/worker.md','ios/scripts/configure.py','ios/scripts/check.py','bin/capture','scripts/secret_refs.py')

def git(*args):
    return subprocess.run(['git',*args],cwd=root,capture_output=True,text=True)

def repo_url(url):
    """One spelling per repository: https, no .git, no trailing slash, lowercase."""
    url=re.sub(r'^(?:ssh://)?git@([^:/]+)[:/]',r'https://\1/',url.strip())
    return re.sub(r'(?:\.git)?/*$','',url).lower()

def guide_url():
    """The URL docs/ios.md tells people to clone, or None."""
    try:match=re.search(r'git clone (\S+)',(root/'docs/ios.md').read_text())
    except OSError:return None
    return match.group(1) if match else None

def default_branch_errors():
    origin=git('remote','get-url','origin').stdout.strip();guide=guide_url()
    if guide and repo_url(origin)!=repo_url(guide):
        return [f'origin is {origin or "not set"}, but the guides clone {guide}. This clone\'s '
                'origin/HEAD says nothing about that repository: run this in a clone of '
                f'{guide} after "git fetch origin".']
    head=git('symbolic-ref','--quiet','refs/remotes/origin/HEAD')
    if head.returncode:
        return ['origin/HEAD is unknown here. Run "git remote set-head origin --auto" (it asks the remote), then run this again.']
    ref=head.stdout.strip();short=ref.replace('refs/remotes/','',1)
    missing=[name for name in HANDOUT if git('cat-file','-e',ref+':'+name).returncode]
    return [f'{short} (as last fetched) has no {name}, so a fresh "git clone" would not either. '
            'Merge and push the branch that has it, run "git fetch origin", then run this again.' for name in missing]

parser=argparse.ArgumentParser(description='Publication safety net (offline).')
parser.add_argument('--default-branch',action='store_true',
                    help='also check that origin/HEAD, as last fetched, has '+', '.join(HANDOUT))
args=parser.parse_args()
paths=subprocess.check_output(['git','ls-files','--cached','--others','--exclude-standard','-z'],cwd=root).decode().split('\0')
errors=[]
for name in sorted(set(paths)-{''}):
    path=root/name
    if (path.is_symlink() or path.suffix.lower() in {'.keystore','.jks','.m4a','.mp3','.wav','.aiff','.sqlite','.db','.apk'}
            or path.name in {'config.json','rclone.conf'} or path.name.startswith('.env')):
        errors.append(name+': forbidden release file');continue
    if not path.is_file():continue
    if path.suffix=='.jar':
        if name!='android/gradle/wrapper/gradle-wrapper.jar':errors.append(name+': unreviewed binary')
        continue
    try:text=path.read_text()
    except UnicodeDecodeError:errors.append(name+': unreviewed binary');continue
    # Detect literal private configuration, not these regex descriptions themselves.
    patterns=[r'/Users/[A-Za-z0-9_-]+/',r'/home/[A-Za-z0-9_-]+/',
              r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
              r'ya29\.[A-Za-z0-9_-]{20,}',r'1//[A-Za-z0-9_-]{30,}',
              r'(?i)(?:access_token|refresh_token)\s*["\']?\s*:\s*["\'][A-Za-z0-9._-]{20,}']
    for pattern in patterns:
        if re.search(pattern,text):errors.append(name+': possible private data');break
if args.default_branch:errors+=default_branch_errors()
if errors:
    print('\n'.join(errors),file=sys.stderr);raise SystemExit(1)
print(f'Checked {len(set(paths)-{""})} candidate files; no forbidden files or configured secret patterns.'
      +(' The default branch has the setup guides and scripts ('
        +git('symbolic-ref','--quiet','--short','refs/remotes/origin/HEAD').stdout.strip()
        +' of '+git('remote','get-url','origin').stdout.strip()+', as last fetched).' if args.default_branch else ''))
