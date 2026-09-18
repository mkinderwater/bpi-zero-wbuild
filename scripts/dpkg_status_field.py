#!/usr/bin/env python3
import argparse
from pathlib import Path
ap = argparse.ArgumentParser()
ap.add_argument('status')
ap.add_argument('--package', required=True)
ap.add_argument('--field', required=True)
a = ap.parse_args()
text = Path(a.status).read_text(errors='replace')
for para in text.split('\n\n'):
    fields = {}
    current = None
    for line in para.splitlines():
        if line.startswith((' ', '\t')) and current:
            fields[current] += '\n' + line[1:]
        elif ': ' in line:
            current, value = line.split(': ', 1)
            fields[current] = value
    if fields.get('Package') == a.package:
        value = fields.get(a.field, '')
        if not value:
            raise SystemExit(f'{a.package}: missing field {a.field}')
        print(value)
        raise SystemExit(0)
raise SystemExit(f'package not found in dpkg status: {a.package}')
