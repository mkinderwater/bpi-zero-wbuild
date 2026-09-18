#!/usr/bin/env python3
import argparse
from pathlib import Path

ap = argparse.ArgumentParser(description='Lock root and remove inherited human login accounts from an offline rootfs.')
ap.add_argument('rootfs')
a = ap.parse_args()
root = Path(a.rootfs)

passwd_p = root / 'etc/passwd'
shadow_p = root / 'etc/shadow'
group_p = root / 'etc/group'
gshadow_p = root / 'etc/gshadow'
for p in (passwd_p, shadow_p, group_p, gshadow_p):
    if not p.is_file():
        raise SystemExit(f'ERROR: required account database missing: {p}')

passwd_lines = passwd_p.read_text().splitlines()
kept_passwd = []
removed = set()
removed_gids = set()
for line in passwd_lines:
    parts = line.split(':')
    if len(parts) < 7:
        raise SystemExit(f'ERROR: malformed passwd entry: {line!r}')
    name = parts[0]
    try:
        uid = int(parts[2])
    except ValueError:
        raise SystemExit(f'ERROR: malformed UID for {name!r}')
    if 1000 <= uid < 60000:
        removed.add(name)
        try:
            removed_gids.add(int(parts[3]))
        except ValueError:
            raise SystemExit(f'ERROR: malformed GID for {name!r}')
        continue
    kept_passwd.append(line)
passwd_p.write_text('\n'.join(kept_passwd) + '\n')

shadow_lines = []
root_seen = False
for line in shadow_p.read_text().splitlines():
    parts = line.split(':')
    if len(parts) < 2:
        raise SystemExit(f'ERROR: malformed shadow entry: {line!r}')
    name = parts[0]
    if name in removed:
        continue
    if name == 'root':
        root_seen = True
        if not parts[1].startswith('!'):
            parts[1] = '!' + parts[1]
        line = ':'.join(parts)
    shadow_lines.append(line)
if not root_seen:
    raise SystemExit('ERROR: root shadow entry is missing')
shadow_p.write_text('\n'.join(shadow_lines) + '\n')

def filter_group_file(path: Path, gshadow: bool) -> None:
    out = []
    for line in path.read_text().splitlines():
        parts = line.split(':')
        if len(parts) != 4:
            raise SystemExit(f'ERROR: malformed group entry in {path}: {line!r}')
        name = parts[0]
        # Remove the private/primary group for any removed human account.
        gid = None
        if not gshadow:
            try:
                gid = int(parts[2])
            except ValueError:
                raise SystemExit(f'ERROR: malformed GID for group {name!r}')
        if name in removed or (gid is not None and gid in removed_gids):
            continue
        members = [x for x in parts[3].split(',') if x and x not in removed]
        parts[3] = ','.join(members)
        if gshadow and parts[2]:
            admins = [x for x in parts[2].split(',') if x and x not in removed]
            parts[2] = ','.join(admins)
        out.append(':'.join(parts))
    path.write_text('\n'.join(out) + '\n')

filter_group_file(group_p, False)
filter_group_file(gshadow_p, True)
final_passwd = passwd_p.read_text().splitlines()
if any(1000 <= int(line.split(':')[2]) < 60000 for line in final_passwd if line):
    raise SystemExit('ERROR: inherited human login account remains after offline cleanup')
root_shadow = next((line.split(':')[1] for line in shadow_p.read_text().splitlines() if line.startswith('root:')), '')
if not root_shadow.startswith(('!', '*')):
    raise SystemExit('ERROR: root account is not locked after offline cleanup')
print('Offline login baseline: root locked; removed inherited human accounts: ' + (', '.join(sorted(removed)) or 'none'))
