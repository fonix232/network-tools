#!/usr/bin/env python3
"""List MMIO-looking constants loaded by Thumb `ldr rX, [pc, #imm]` in an MX6600 app image.

Usage: python3 -I mmio_literals.py IMAGE.bin [text_end_hex]
Groups the constants by 64 KiB block and counts the loading sites, which shows
which peripheral bases the firmware touches. text_end defaults to 0x2d3d8 (V1.2.7).
"""
import collections, struct, sys

d = open(sys.argv[1], 'rb').read()
text_end = int(sys.argv[2], 16) if len(sys.argv) > 2 else 0x2d3d8
blocks = collections.defaultdict(collections.Counter)
for pc in range(0x114, text_end, 2):
    hw = struct.unpack_from('<H', d, pc)[0]
    if hw >> 11 != 0b01001:
        continue
    lit = ((pc + 4) & ~3) + (hw & 0xff) * 4
    if lit + 4 > text_end:
        continue
    v = struct.unpack_from('<I', d, lit)[0]
    if 0x40000000 <= v < 0x60000000 or 0xe0000000 <= v < 0xe0100000 or 0x00080000 <= v < 0x00200000:
        blocks[v & 0xffff0000][v] += 1
for base in sorted(blocks):
    c = blocks[base]
    regs = ', '.join(f'{a:08x}x{n}' for a, n in sorted(c.items())[:12])
    print(f'{base:08x}: {sum(c.values()):4d} loads, {len(c):3d} distinct  [{regs}{" ..." if len(c) > 12 else ""}]')
