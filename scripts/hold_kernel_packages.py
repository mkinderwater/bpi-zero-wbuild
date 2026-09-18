#!/usr/bin/env python3
import argparse, pathlib

ap=argparse.ArgumentParser()
ap.add_argument('status')
ap.add_argument('--require', required=True)
a=ap.parse_args()
p=pathlib.Path(a.status)
text=p.read_text()
paras=text.split('\n\n')
held=[]
out=[]
for para in paras:
    lines=para.splitlines()
    pkg=next((x.split(':',1)[1].strip() for x in lines if x.startswith('Package:')), '')
    if pkg.startswith(('linux-image-', 'linux-headers-', 'linux-kbuild-')):
        for i,line in enumerate(lines):
            if line.startswith('Status:') and line.endswith(' ok installed'):
                lines[i]='Status: hold ok installed'
                held.append(pkg)
                break
    out.append('\n'.join(lines))
if a.require not in held:
    raise SystemExit(f'ERROR: required kernel package was not marked hold: {a.require}')
p.write_text('\n\n'.join(out))
print('Kernel packages held: ' + ', '.join(held))
