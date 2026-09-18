#!/usr/bin/env python3
"""Strict Device Tree GPIO specifier walking helpers.

A *-gpios property is a heterogeneous list of phandle-led GPIO specifiers.
The number of cells following each phandle comes from that controller's
#gpio-cells property. A zero phandle is the standard one-cell empty/native
placeholder and consumes only that cell.
"""
from fdt_read import decu32


def _one_u32(raw, what):
    vals = decu32(raw)
    if len(vals) != 1:
        raise ValueError(f'{what} must contain exactly one u32 cell')
    return vals[0]


def gpio_controllers(paths):
    """Return phandle -> (path, node, #gpio-cells) for every GPIO controller."""
    out = {}
    for path, node in paths:
        raw_cells = node.props.get('#gpio-cells')
        if raw_cells is None:
            continue
        count = _one_u32(raw_cells, f'{path}:#gpio-cells')
        if count < 1 or count > 8:
            raise ValueError(f'{path}: unreasonable #gpio-cells={count}')
        rawh = node.props.get('phandle') or node.props.get('linux,phandle')
        if not rawh:
            continue
        ph = _one_u32(rawh, f'{path}:phandle')
        if ph == 0:
            raise ValueError(f'{path}: GPIO controller has zero phandle')
        if ph in out and out[ph][0] != path:
            raise ValueError(f'duplicate GPIO controller phandle 0x{ph:x}: {out[ph][0]} and {path}')
        out[ph] = (path, node, count)
    return out


def walk_gpio_property(raw, controllers, context='gpio property'):
    """Yield (phandle, controller_path, args) entry-by-entry.

    phandle 0 is a one-cell placeholder such as native SPI chip select and is
    yielded as (0, None, ()). Unknown GPIO controller phandles fail closed.
    """
    cells = decu32(raw)
    i = 0
    while i < len(cells):
        ph = cells[i]
        if ph == 0:
            yield 0, None, ()
            i += 1
            continue
        controller = controllers.get(ph)
        if controller is None:
            raise ValueError(f'{context}: unresolved GPIO controller phandle 0x{ph:x} at cell {i}')
        controller_path, _node, narg = controller
        end = i + 1 + narg
        if end > len(cells):
            raise ValueError(
                f'{context}: truncated GPIO specifier for {controller_path}: '
                f'needs {narg} argument cells after phandle 0x{ph:x}'
            )
        args = tuple(cells[i + 1:end])
        yield ph, controller_path, args
        i = end


def walk_gpio_hog(raw, gpio_cells, context='gpio-hog'):
    """Yield local GPIO hog argument tuples (no controller phandle in property)."""
    cells = decu32(raw)
    if gpio_cells < 1:
        raise ValueError(f'{context}: invalid #gpio-cells={gpio_cells}')
    if len(cells) % gpio_cells:
        raise ValueError(
            f'{context}: {len(cells)} cells is not divisible by controller #gpio-cells={gpio_cells}'
        )
    for i in range(0, len(cells), gpio_cells):
        yield tuple(cells[i:i + gpio_cells])
