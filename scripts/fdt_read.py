import struct
from collections import OrderedDict
from pathlib import Path

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def align4(x):
    return (x + 3) & ~3


class Node:
    def __init__(self, name, parent=None):
        self.name = name
        self.parent = parent
        self.props = OrderedDict()
        self.children = []

    def child(self, name):
        return next((c for c in self.children if c.name == name), None)


def _fail(message):
    raise ValueError(f'malformed DTB: {message}')


def parse(path):
    data = Path(path).read_bytes()
    if len(data) < 40:
        _fail(f'header is truncated ({len(data)} bytes)')
    try:
        (magic, totalsize, off_struct, off_strings, off_mem_rsvmap,
         version, last_comp_version, boot_cpuid_phys, size_strings,
         size_struct) = struct.unpack('>10I', data[:40])
    except struct.error as exc:
        _fail(f'cannot unpack header: {exc}')
    if magic != FDT_MAGIC:
        _fail(f'bad magic 0x{magic:08x}')
    if totalsize < 40 or totalsize > len(data):
        _fail(f'invalid totalsize {totalsize} for file size {len(data)}')
    if off_struct % 4:
        _fail(f'structure block offset {off_struct} is not 4-byte aligned')
    if off_strings > totalsize or size_strings > totalsize - off_strings:
        _fail('strings block exceeds totalsize')
    if off_struct > totalsize or size_struct > totalsize - off_struct:
        _fail('structure block exceeds totalsize')
    if off_mem_rsvmap >= totalsize:
        _fail('memory reservation block offset exceeds totalsize')
    if version < 16 or last_comp_version > version:
        _fail(f'unsupported header version {version}/{last_comp_version}')

    strings = data[off_strings:off_strings + size_strings]
    pos, end = off_struct, off_struct + size_struct
    stack, root = [], None
    saw_end = False

    def require(n, what):
        if pos + n > end:
            _fail(f'truncated {what} at structure offset {pos - off_struct}')

    while pos < end:
        require(4, 'token')
        tok = struct.unpack('>I', data[pos:pos + 4])[0]
        pos += 4
        if tok == FDT_BEGIN_NODE:
            try:
                z = data.index(b'\0', pos, end)
            except ValueError:
                _fail('unterminated node name')
            name = data[pos:z].decode(errors='replace')
            pos = align4(z + 1)
            if pos > end:
                _fail('node name padding exceeds structure block')
            node = Node(name, stack[-1] if stack else None)
            if stack:
                stack[-1].children.append(node)
            elif root is None:
                root = node
            else:
                _fail('multiple root nodes')
            stack.append(node)
        elif tok == FDT_END_NODE:
            if not stack:
                _fail('END_NODE without matching BEGIN_NODE')
            stack.pop()
        elif tok == FDT_PROP:
            if not stack:
                _fail('property outside a node')
            require(8, 'property header')
            length, nameoff = struct.unpack('>II', data[pos:pos + 8])
            pos += 8
            if nameoff >= size_strings:
                _fail(f'property name offset {nameoff} exceeds strings block')
            z = strings.find(b'\0', nameoff)
            if z < 0:
                _fail(f'unterminated property name at string offset {nameoff}')
            try:
                name = strings[nameoff:z].decode()
            except UnicodeDecodeError as exc:
                _fail(f'invalid property name encoding: {exc}')
            require(length, f'property {name!r}')
            value = data[pos:pos + length]
            pos = align4(pos + length)
            if pos > end:
                _fail(f'property {name!r} padding exceeds structure block')
            stack[-1].props[name] = value
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            if stack:
                _fail('FDT_END encountered with unclosed nodes')
            saw_end = True
            break
        else:
            _fail(f'unknown FDT token 0x{tok:x}')

    if root is None:
        _fail('no root node')
    if not saw_end:
        _fail('missing FDT_END token')
    return root


def get(root, path):
    if path == '/':
        return root
    node = root
    for part in path.strip('/').split('/'):
        node = node.child(part)
        if node is None:
            raise KeyError(path)
    return node


def decstr(value):
    return value.rstrip(b'\0').decode(errors='replace')


def declist(value):
    return [x.decode(errors='replace') for x in value.split(b'\0') if x]


def decu32(value):
    if len(value) % 4:
        raise ValueError(f'u32 property has non-multiple-of-4 length {len(value)}')
    return struct.unpack('>' + ('I' * (len(value) // 4)), value)


def walk(node, path='/'):
    yield path, node
    for child in node.children:
        child_path = ('/' + child.name) if path == '/' else (path.rstrip('/') + '/' + child.name)
        yield from walk(child, child_path)


def prop_u32(node, name):
    if name not in node.props:
        raise KeyError(name)
    return decu32(node.props[name])


def effective_enabled(path, nodes_by_path):
    """True only when this node and every ancestor are enabled."""
    current = path
    while True:
        node = nodes_by_path.get(current)
        if node is None:
            raise KeyError(current)
        status = decstr(node.props.get('status', b'okay\0'))
        if status not in ('okay', 'ok', ''):
            return False
        if current == '/':
            return True
        parent = current.rsplit('/', 1)[0] or '/'
        current = parent
