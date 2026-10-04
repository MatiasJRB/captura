#!/usr/bin/env python3
"""Small publication safety net, not a secret-scanning or legal-audit guarantee."""
from pathlib import Path
import re
import subprocess
import sys
root=Path(__file__).resolve().parents[1]
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
if errors:
    print('\n'.join(errors),file=sys.stderr);raise SystemExit(1)
print(f'Checked {len(set(paths)-{""})} candidate files; no forbidden files or configured secret patterns.')
