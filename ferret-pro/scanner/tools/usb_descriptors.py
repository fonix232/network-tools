#!/usr/bin/env python3
"""Find and decode the USB descriptors embedded in an MX6600 scanner app image.

Usage: python3 -I usb_descriptors.py MX6600_CRScan_Ferret_App_V1.2.7.bin
Scans for device (0x12 0x01) and configuration (0x09 0x02) descriptors whose
wTotalLength walks cleanly as a descriptor chain, then prints the tree.
"""
import struct, sys, uuid

VC_SUB = {1: 'VC_HEADER', 2: 'INPUT_TERMINAL', 3: 'OUTPUT_TERMINAL', 4: 'SELECTOR_UNIT',
          5: 'PROCESSING_UNIT', 6: 'EXTENSION_UNIT'}
VS_SUB = {1: 'VS_INPUT_HEADER', 3: 'STILL_IMAGE_FRAME', 4: 'FORMAT_UNCOMPRESSED',
          5: 'FRAME_UNCOMPRESSED', 6: 'FORMAT_MJPEG', 7: 'FRAME_MJPEG', 0x0d: 'COLORFORMAT',
          0x10: 'FORMAT_FRAME_BASED', 0x11: 'FRAME_FRAME_BASED'}
XFER = ['control', 'iso', 'bulk', 'interrupt']


def chain_ok(d, off, total):
    end, p = off + total, off
    while p < end:
        ln = d[p]
        if ln < 2 or p + ln > end:
            return False
        p += ln
    return p == end


def guid(b):
    return str(uuid.UUID(bytes_le=bytes(b)))


def fourcc(b):
    s = bytes(b[:4])
    return s.decode('ascii', 'replace').strip() if all(32 <= c < 127 for c in s) else guid(b)


def dump_config(d, off):
    total = struct.unpack_from('<H', d, off + 2)[0]
    print(f'== configuration @0x{off:x} wTotalLength={total} bNumInterfaces={d[off+4]} '
          f'bmAttributes=0x{d[off+7]:02x} bMaxPower={d[off+8]}')
    p, end, cur_class, cur_sub = off + 9, off + total, None, None
    while p < end:
        ln, ty = d[p], d[p + 1]
        b = d[p:p + ln]
        if ty == 4:
            cur_class, cur_sub = b[5], b[6]
            print(f'  IF {b[2]} alt {b[3]} eps={b[4]} class={b[5]:02x}/{b[6]:02x}/{b[7]:02x} iIf={b[8]}')
        elif ty == 0x0b:
            print(f'  IAD first={b[2]} count={b[3]} class={b[4]:02x}/{b[5]:02x} iFunc={b[7]}')
        elif ty == 5:
            mps = struct.unpack_from('<H', b, 4)[0]
            print(f'    EP 0x{b[2]:02x} {XFER[b[3] & 3]} maxpkt={mps & 0x7ff} (x{(mps >> 11) + 1}) interval={b[6]}')
        elif ty == 0x30:
            print(f'    SS companion maxburst={b[2]} attr=0x{b[3]:02x} bytesPerInterval={struct.unpack_from("<H", b, 4)[0]}')
        elif ty == 0x24 and cur_class == 0x0e and cur_sub == 1:
            st = VC_SUB.get(b[2], hex(b[2]))
            extra = ''
            if b[2] == 1:
                extra = f'bcdUVC={struct.unpack_from("<H", b, 3)[0]:04x} clock={struct.unpack_from("<I", b, 7)[0]}'
            elif b[2] == 2:
                extra = f'id={b[3]} type=0x{struct.unpack_from("<H", b, 4)[0]:04x}'
            elif b[2] == 3:
                extra = f'id={b[3]} type=0x{struct.unpack_from("<H", b, 4)[0]:04x} src={b[7]}'
            elif b[2] == 5:
                extra = f'id={b[3]} src={b[4]} controls={b[8:8+b[7]].hex()}'
            elif b[2] == 6:
                n = b[21]
                csz = b[22 + n]
                extra = (f'id={b[3]} guid={guid(b[4:20])} numControls={b[20]} sources={list(b[22:22+n])} '
                         f'bmControls={b[23+n:23+n+csz].hex()}')
            print(f'    VC {st} {extra}')
        elif ty == 0x24 and cur_class == 0x0e and cur_sub == 2:
            st = VS_SUB.get(b[2], hex(b[2]))
            if b[2] == 1:
                print(f'    VS {st} nformats={b[3]} ep=0x{b[6]:02x} terminalLink={b[8]}')
            elif b[2] in (4, 0x10):
                print(f'    VS {st} idx={b[3]} nframes={b[4]} fourcc={fourcc(b[5:21])} bpp={b[21]}')
            elif b[2] == 6:
                print(f'    VS {st} idx={b[3]} nframes={b[4]}')
            elif b[2] in (5, 7, 0x11):
                w, h = struct.unpack_from('<HH', b, 5)
                if b[2] == 0x11:
                    dflt = struct.unpack_from('<I', b, 17)[0]; n = b[21]; ivs = b[26:26 + 4 * max(n, 1)]
                else:
                    dflt = struct.unpack_from('<I', b, 21)[0]; n = b[25]; ivs = b[26:26 + 4 * max(n, 1)]
                fps = sorted({round(1e7 / v) for v in struct.unpack(f'<{len(ivs)//4}I', ivs) if v})
                print(f'      frame {b[3]}: {w}x{h} fps={fps}')
            else:
                print(f'    VS {st} {b.hex()}')
        else:
            print(f'    desc type=0x{ty:02x} {b.hex()}')
        p += ln


def main(path):
    d = open(path, 'rb').read()
    for off in range(len(d) - 18):
        if d[off] == 0x12 and d[off + 1] == 1 and d[off + 7] in (8, 9, 16, 32, 64):
            bcd, cls, sub, proto, mps, vid, pid, dev = struct.unpack_from('<HBBBBHHH', d, off + 2)
            if vid == 0x2bc5:
                print(f'== device @0x{off:x} bcdUSB={bcd:04x} class={cls:02x}/{sub:02x}/{proto:02x} '
                      f'ep0={mps} VID={vid:04x} PID={pid:04x} bcdDevice={dev:04x} '
                      f'iMfr={d[off+14]} iProd={d[off+15]} iSer={d[off+16]} nCfg={d[off+17]}')
    for off in range(len(d) - 9):
        if d[off] == 9 and d[off + 1] == 2:
            total = struct.unpack_from('<H', d, off + 2)[0]
            if 0x19 <= total < 0x4000 and d[off + 9:off + 11] in (b'\x09\x04', b'\x08\x0b') and chain_ok(d, off, total):
                dump_config(d, off)


if __name__ == '__main__':
    main(sys.argv[1])
