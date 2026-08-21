#!/usr/bin/env python3
import argparse, pathlib, re

ap = argparse.ArgumentParser()
ap.add_argument('extlinux_conf')
ap.add_argument('u_boot_defaults')
ap.add_argument('--partuuid', required=True)
args = ap.parse_args()

conf = pathlib.Path(args.extlinux_conf)
defs = pathlib.Path(args.u_boot_defaults)
text = conf.read_text()
lines = text.splitlines()
append_count = sum(1 for line in lines if re.match(r'^\s*append\s+', line))
if append_count != 1:
    raise SystemExit(f'expected exactly one extlinux append line, found {append_count}')

out=[]
seen_prompt=seen_timeout=False
for line in lines:
    if re.match(r'^\s*prompt\s+', line):
        out.append('prompt 0'); seen_prompt=True
    elif re.match(r'^\s*timeout\s+', line):
        out.append('timeout 10'); seen_timeout=True
    elif re.match(r'^\s*append\s+', line):
        indent=line[:len(line)-len(line.lstrip())]
        out.append(f'{indent}append root=PARTUUID={args.partuuid} rw rootwait quiet loglevel=4')
    else:
        out.append(line)
if not seen_prompt:
    raise SystemExit('extlinux prompt setting missing')
if not seen_timeout:
    raise SystemExit('extlinux timeout setting missing')
conf.write_text('\n'.join(out)+'\n')

def upsert(data, key, value):
    pat=re.compile(rf'^{re.escape(key)}=.*$', re.M)
    line=f'{key}="{value}"'
    if pat.search(data):
        return pat.sub(line, data)
    return data.rstrip()+'\n'+line+'\n'

data = defs.read_text() if defs.exists() else ''
data = upsert(data, 'U_BOOT_ROOT', f'root=PARTUUID={args.partuuid}')
data = upsert(data, 'U_BOOT_PARAMETERS', 'rw rootwait quiet loglevel=4')
data = upsert(data, 'U_BOOT_PROMPT', '0')
data = upsert(data, 'U_BOOT_TIMEOUT', '10')
defs.write_text(data if data.endswith('\n') else data+'\n')
