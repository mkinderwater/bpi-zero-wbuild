#!/usr/bin/env python3
import sys
from pathlib import Path
from fdt_read import parse, get, decstr, declist, walk, effective_enabled

if len(sys.argv) != 2:
    raise SystemExit(f'usage: {Path(sys.argv[0]).name} DTB')
try:
    root = parse(sys.argv[1])
except (OSError, ValueError) as exc:
    raise SystemExit(f'ERROR: {exc}')
paths = list(walk(root))
by_path = dict(paths)
try:
    aliases = get(root, '/aliases')
except KeyError:
    raise SystemExit('ERROR: DTB has no /aliases node')
raw = aliases.props.get('serial1')
if not raw:
    raise SystemExit('ERROR: DTB has no aliases:serial1 for AP6212 Bluetooth UART')
uart_path = decstr(raw)
try:
    uart = get(root, uart_path)
except KeyError:
    raise SystemExit(f'ERROR: serial1 points to missing node {uart_path}')
if not effective_enabled(uart_path, by_path):
    raise SystemExit(f'ERROR: Bluetooth UART {uart_path} is disabled by its node or an ancestor')
if 'uart-has-rtscts' not in uart.props:
    raise SystemExit(f'ERROR: Bluetooth UART {uart_path} lacks uart-has-rtscts')
bluetooth = None
bluetooth_path = None
for child in uart.children:
    compat = declist(child.props.get('compatible', b''))
    if 'brcm,bcm43438-bt' in compat:
        bluetooth = child
        bluetooth_path = uart_path.rstrip('/') + '/' + child.name
        break
if bluetooth is None:
    raise SystemExit(f'ERROR: {uart_path} has no brcm,bcm43438-bt serdev child')
if not effective_enabled(bluetooth_path, by_path):
    raise SystemExit(f'ERROR: Bluetooth serdev child {bluetooth_path} is disabled by its node or an ancestor')
print(f'Bluetooth DT topology OK: serial1={uart_path}, child={bluetooth.name}, compatible=brcm,bcm43438-bt')
