#!/usr/bin/env python3
import sys
from collections import defaultdict
from pathlib import Path
from fdt_read import parse, get, decu32, declist, decstr, walk, effective_enabled
from gpio_spec import gpio_controllers, walk_gpio_property, walk_gpio_hog

if len(sys.argv) != 2:
    raise SystemExit(f'usage: {Path(sys.argv[0]).name} DTB')
try:
    root = parse(sys.argv[1])
except (OSError, ValueError) as exc:
    raise SystemExit(f'ERROR: {exc}')
paths = list(walk(root))
by_path = dict(paths)
pio_path = '/soc/pinctrl@1c20800'
try:
    pio = get(root, pio_path)
except KeyError:
    raise SystemExit(f'ERROR: missing pin controller {pio_path}')
raw = pio.props.get('phandle') or pio.props.get('linux,phandle')
if not raw:
    raise SystemExit(f'ERROR: {pio_path} has no phandle')
pio_phandle = decu32(raw)[0]

try:
    controllers = gpio_controllers(paths)
except ValueError as exc:
    raise SystemExit(f'ERROR: {exc}')
if pio_phandle not in controllers:
    raise SystemExit(f'ERROR: {pio_path} is not described as a GPIO controller with #gpio-cells')
pio_gpio_cells = controllers[pio_phandle][2]


def enabled(path):
    return effective_enabled(path, by_path)


# Resolve pinctrl groups by phandle across every effectively enabled controller,
# including the H3 always-on R_PIO controller. Resolution is not ownership, but
# disabled controller subtrees are not meaningful pin groups for this contract.
groups = {}
for path, node in paths:
    if not enabled(path):
        continue
    pins = declist(node.props.get('pins', b''))
    function = decstr(node.props.get('function', b''))
    if not pins or not function:
        continue
    rawh = node.props.get('phandle') or node.props.get('linux,phandle')
    if rawh and len(rawh) >= 4:
        groups[decu32(rawh)[0]] = (path, pins, function)
group_paths = {group[0] for group in groups.values()}


def consumer_groups(path, strict=False):
    node = by_path[path]
    names = declist(node.props.get('pinctrl-names', b''))
    rawp = node.props.get('pinctrl-0', b'')
    if names and 'default' in names and not rawp:
        if strict:
            raise SystemExit(f'ERROR: {path} names a default pinctrl state but has no pinctrl-0')
        return []
    if not rawp:
        return []
    if len(rawp) % 4:
        if strict:
            raise SystemExit(f'ERROR: {path}:pinctrl-0 has malformed length {len(rawp)}')
        return []
    out = []
    for ph in decu32(rawp):
        group = groups.get(ph)
        if group is None:
            if strict:
                raise SystemExit(f'ERROR: {path}:pinctrl-0 references unresolved phandle 0x{ph:x}')
            continue
        out.append(group)
    return out


# Enforce exact pinmux for the generic buses this image enables.
expected = {
    '/soc/i2c@1c2ac00': ({'PA11', 'PA12'}, 'i2c0', 'I2C0'),
    '/soc/i2s@1c22000': ({'PA18', 'PA19', 'PA20'}, 'i2s0', 'I2S0'),
}
for path, (pins_expected, function_expected, label) in expected.items():
    if path not in by_path or not enabled(path):
        raise SystemExit(f'ERROR: {label} node {path} is not effectively enabled')
    cg = consumer_groups(path, strict=True)
    pins = {p for _, ps, fn in cg if fn == function_expected for p in ps}
    if pins != pins_expected:
        raise SystemExit(f'ERROR: {label} active {function_expected} pins are {sorted(pins)}, expected {sorted(pins_expected)}')

spi_path = '/soc/spi@1c68000'
if spi_path not in by_path or not enabled(spi_path):
    raise SystemExit(f'ERROR: SPI0 node {spi_path} is not effectively enabled')
spi_groups = consumer_groups(spi_path, strict=True)
spi_pins = {p for _, ps, fn in spi_groups if fn == 'spi0' for p in ps}
if not spi_pins:
    raise SystemExit('ERROR: SPI0 has no active pinctrl group with function=spi0')

# Detect cross-owner pin conflicts among effectively enabled default pinctrl
# groups across all controllers. Unrelated unresolved upstream phandles are
# ignored here; the buses owned by this image were already checked strictly.
claims = defaultdict(list)
for path, node in paths:
    if path in group_paths or not enabled(path):
        continue
    for group_path, pins, function in consumer_groups(path, strict=False):
        for pin in pins:
            claims[pin].append((path, f'pinctrl:{group_path}', function or 'unknown'))

# Walk heterogeneous *-gpios arrays by resolving #gpio-cells for each phandle.
# This correctly handles idioms such as cs-gpios = <0>, <&pio 0 7 0>.
for path, node in paths:
    if not enabled(path):
        continue
    for prop, rawv in node.props.items():
        if not (prop == 'gpios' or prop.endswith('-gpios')):
            continue
        try:
            for ph, controller_path, args in walk_gpio_property(rawv, controllers, f'{path}:{prop}'):
                if ph != pio_phandle or controller_path != pio_path:
                    continue
                if len(args) < 2:
                    raise ValueError(f'{path}:{prop}: main PIO GPIO specifier has only {len(args)} argument cells')
                bank, pin = args[0], args[1]
                if 0 <= bank <= 25:
                    claims[f'P{chr(ord("A") + bank)}{pin}'].append((path, prop, 'gpio'))
                else:
                    claims[f'PBANK{bank}_{pin}'].append((path, prop, 'gpio'))
        except ValueError as exc:
            raise SystemExit(f'ERROR: {exc}')


# The base audio endpoint must own PA1 as MAX98357A SD/EN.
max_path = '/max98357a'
if max_path not in by_path or not enabled(max_path):
    raise SystemExit('ERROR: MAX98357A node is not effectively enabled')
max_sd_claims = []
raw_sd = by_path[max_path].props.get('sdmode-gpios', b'')
try:
    for ph, controller_path, args in walk_gpio_property(raw_sd, controllers, f'{max_path}:sdmode-gpios'):
        if ph == pio_phandle and controller_path == pio_path and len(args) >= 2:
            bank, pin = args[0], args[1]
            max_sd_claims.append((bank, pin))
except ValueError as exc:
    raise SystemExit(f'ERROR: {exc}')
if max_sd_claims != [(0, 1)]:
    raise SystemExit(f'ERROR: MAX98357A sdmode-gpios must claim PA1 exactly, found {max_sd_claims}')

# GPIO hog specifiers omit the controller phandle because they live below it.
for path, node in paths:
    if not path.startswith(pio_path + '/') or 'gpio-hog' not in node.props or not enabled(path):
        continue
    rawv = node.props.get('gpios', b'')
    try:
        for args in walk_gpio_hog(rawv, pio_gpio_cells, f'{path}:gpios'):
            if len(args) < 2:
                raise ValueError(f'{path}:gpio-hog specifier has only {len(args)} cells')
            bank, pin = args[0], args[1]
            if 0 <= bank <= 25:
                claims[f'P{chr(ord("A") + bank)}{pin}'].append((path, 'gpio-hog', 'gpio'))
            else:
                claims[f'PBANK{bank}_{pin}'].append((path, 'gpio-hog', 'gpio'))
    except ValueError as exc:
        raise SystemExit(f'ERROR: {exc}')

conflicts = []
for pin, entries in claims.items():
    owners = {owner for owner, _, _ in entries}
    if len(owners) > 1:
        conflicts.append((pin, entries))
if conflicts:
    for pin, entries in sorted(conflicts):
        detail = '; '.join(f'{owner}:{source}({function})' for owner, source, function in entries)
        print(f'ERROR: pin {pin} has multiple enabled owners: {detail}', file=sys.stderr)
    raise SystemExit(1)
print('Platform pin contract OK: I2C0 PA11/PA12, I2S0 PA18/PA19/PA20, MAX98357A PA1 and SPI0 active; pinctrl/GPIO claims have no cross-owner conflicts')
