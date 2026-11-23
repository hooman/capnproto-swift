"""Schema-agnostic Cap'n Proto message codec for test harnesses.

Pointers describe their own targets, so any unpacked message decodes into a tree of Struct,
List and capability-free values without a schema. The tree is re-encoded as one segment.
This lets a harness edit a CodeGeneratorRequest structurally (copy a node, change an ID)
even when capnp's text and JSON forms cannot round-trip it: the text form prints AnyPointer
default values as `<opaque pointer>`, and the JSON codec refuses AnyPointer.

Not a general library: capability pointers are rejected, and only what a well-formed
request needs is supported (single- and double-far pointers, all list element sizes).
"""
import struct
from dataclasses import dataclass, field

# List element size codes and their widths in bits (inline composite is handled separately).
BITS = {0: 0, 1: 1, 2: 8, 3: 16, 4: 32, 5: 64}


@dataclass
class Struct:
    data: bytearray
    pointers: list = field(default_factory=list)

    def u64(self, word):
        return struct.unpack_from('<Q', self.data, word * 8)[0] if word * 8 + 8 <= len(self.data) else 0

    def set_u64(self, word, value):
        struct.pack_into('<Q', self.data, word * 8, value)


@dataclass
class List:
    size: int                     # element size code, 0-7
    count: int
    raw: bytes = b''              # sizes 0-5: packed element bytes
    items: list = field(default_factory=list)   # size 6: pointers; size 7: Structs
    data_words: int = 0           # size 7 only
    pointer_count: int = 0        # size 7 only


def _signed30(value):
    return value - (1 << 30) if value & (1 << 29) else value


def decode(message):
    """Decode a framed, unpacked message into its root (a Struct, List or None)."""
    count = struct.unpack_from('<I', message, 0)[0] + 1
    sizes = struct.unpack_from(f'<{count}I', message, 4)
    offset = 4 + 4 * count
    offset += (-offset) % 8
    segments = []
    for size in sizes:
        segments.append(message[offset:offset + size * 8])
        offset += size * 8
    assert offset == len(message), 'trailing bytes after the last segment'

    def word(segment, index):
        return struct.unpack_from('<Q', segments[segment], index * 8)[0]

    def read(segment, index, value=None, target=None):
        # `value` and `target` let a far pointer's landing pad describe content elsewhere.
        if value is None:
            value = word(segment, index)
        if value == 0:
            return None
        kind = value & 3
        if kind == 2:
            pad_segment, pad = value >> 32, (value >> 3) & 0x1FFFFFFF
            if not (value >> 2) & 1:
                return read(pad_segment, pad)
            landing = word(pad_segment, pad)
            assert landing & 7 == 2, 'double-far landing pad is not a single far pointer'
            return read(pad_segment, pad + 1, word(pad_segment, pad + 1),
                        (landing >> 32, (landing >> 3) & 0x1FFFFFFF))
        assert kind != 3, 'capability pointers are not supported'
        if target is None:
            target = (segment, index + 1 + _signed30((value >> 2) & 0x3FFFFFFF))
        seg, start = target
        if kind == 0:
            data_words, pointer_count = (value >> 32) & 0xFFFF, value >> 48
            data = bytearray(segments[seg][start * 8:(start + data_words) * 8])
            pointers = [read(seg, start + data_words + i) for i in range(pointer_count)]
            return Struct(data, pointers)
        size, count = (value >> 32) & 7, value >> 35
        if size == 7:
            tag = word(seg, start)
            elements = (tag >> 2) & 0x3FFFFFFF
            data_words, pointer_count = (tag >> 32) & 0xFFFF, tag >> 48
            stride = data_words + pointer_count
            assert elements * stride <= count, 'inline composite tag exceeds its word count'
            items = []
            for i in range(elements):
                base = start + 1 + i * stride
                data = bytearray(segments[seg][base * 8:(base + data_words) * 8])
                items.append(Struct(data, [read(seg, base + data_words + j) for j in range(pointer_count)]))
            return List(7, elements, items=items, data_words=data_words, pointer_count=pointer_count)
        if size == 6:
            return List(6, count, items=[read(seg, start + i) for i in range(count)])
        length = (count * BITS[size] + 7) // 8
        return List(size, count, raw=bytes(segments[seg][start * 8:start * 8 + length]))

    return read(0, 0)


def encode(root):
    """Encode a tree from decode() as a framed, single-segment message."""
    words = [0]

    def alloc(count):
        start = len(words)
        words.extend([0] * count)
        return start

    def put_bytes(start, data):
        padded = bytes(data) + b'\0' * ((-len(data)) % 8)
        for i in range(len(padded) // 8):
            words[start + i] = struct.unpack_from('<Q', padded, i * 8)[0]

    def offset_bits(at, target):
        return ((target - at - 1) & 0x3FFFFFFF) << 2

    def write(at, value):
        if value is None:
            return
        if isinstance(value, Struct):
            data_words = (len(value.data) + 7) // 8
            start = alloc(data_words + len(value.pointers))
            put_bytes(start, value.data)
            if data_words == 0 and not value.pointers:
                words[at] = 0xFFFFFFFC   # zero-sized struct: offset -1, so the pointer is not null
                return
            words[at] = offset_bits(at, start) | (data_words << 32) | (len(value.pointers) << 48)
            for i, pointer in enumerate(value.pointers):
                write(start + data_words + i, pointer)
            return
        if value.size == 7:
            stride = value.data_words + value.pointer_count
            start = alloc(1 + value.count * stride)
            words[start] = (value.count << 2) | (value.data_words << 32) | (value.pointer_count << 48)
            words[at] = 1 | offset_bits(at, start) | (7 << 32) | ((value.count * stride) << 35)
            for i, item in enumerate(value.items):
                base = start + 1 + i * stride
                data = bytes(item.data[:value.data_words * 8])
                put_bytes(base, data + b'\0' * (value.data_words * 8 - len(data)))
                for j in range(value.pointer_count):
                    write(base + value.data_words + j, item.pointers[j] if j < len(item.pointers) else None)
            return
        if value.size == 6:
            start = alloc(value.count)
            words[at] = 1 | offset_bits(at, start) | (6 << 32) | (value.count << 35)
            for i, item in enumerate(value.items):
                write(start + i, item)
            return
        start = alloc((len(value.raw) + 7) // 8)
        put_bytes(start, value.raw)
        words[at] = 1 | offset_bits(at, start) | (value.size << 32) | (value.count << 35)

    write(0, root)
    return struct.pack('<II', 0, len(words)) + struct.pack(f'<{len(words)}Q', *words)
