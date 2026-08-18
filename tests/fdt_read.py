import struct
from collections import OrderedDict

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

def parse(path):
    data = open(path, 'rb').read()
    hdr = struct.unpack('>10I', data[:40])
    magic, _, off_struct, off_strings, _, _, _, _, size_strings, size_struct = hdr
    assert magic == FDT_MAGIC
    strings = data[off_strings:off_strings + size_strings]
    pos, end = off_struct, off_struct + size_struct
    stack, root = [], None
    while pos < end:
        tok = struct.unpack('>I', data[pos:pos + 4])[0]
        pos += 4
        if tok == FDT_BEGIN_NODE:
            z = data.index(b'\0', pos, end)
            name = data[pos:z].decode(errors='replace')
            pos = align4(z + 1)
            node = Node(name, stack[-1] if stack else None)
            if stack:
                stack[-1].children.append(node)
            else:
                root = node
            stack.append(node)
        elif tok == FDT_END_NODE:
            stack.pop()
        elif tok == FDT_PROP:
            length, nameoff = struct.unpack('>II', data[pos:pos + 8])
            pos += 8
            z = strings.find(b'\0', nameoff)
            name = strings[nameoff:z].decode()
            value = data[pos:pos + length]
            pos = align4(pos + length)
            stack[-1].props[name] = value
        elif tok == FDT_NOP:
            pass
        elif tok == FDT_END:
            break
        else:
            raise ValueError(f'bad FDT token {tok:x}')
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
    return [x.decode() for x in value.split(b'\0') if x]

def decu32(value):
    return struct.unpack('>' + ('I' * (len(value) // 4)), value)
