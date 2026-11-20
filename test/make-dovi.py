"""Marks the HEVC track of an mp4, whose moov follows its mdat, as Dolby Vision of a profile and base layer, 8.1 if not given."""
import struct
import sys


def find(data, start, end, kind):
    at = start
    while at + 8 <= end:
        size, found = struct.unpack('>I4s', data[at:at + 8])
        if found == kind:
            return at, size
        at += max(size, 8)
    raise SystemExit('no %s box' % kind.decode())


def main(path, profile=8, compatibility=1):
    data = bytearray(open(path, 'rb').read())
    moov = find(data, 0, len(data), b'moov')
    chain = [moov, find(data, moov[0] + 8, sum(moov), b'trak')]
    for kind in (b'mdia', b'minf', b'stbl', b'stsd'):
        chain.append(find(data, chain[-1][0] + 8, sum(chain[-1]), kind))
    chain.append(find(data, chain[-1][0] + 16, sum(chain[-1]), b'hvc1'))
    # Version 1.0, then the profile, level 6, an RPU and a base layer, then the compatibility of the base layer.
    payload = struct.pack('>BBHI', 1, 0, (profile << 9) | (6 << 3) | (1 << 2) | 1, compatibility << 28) + bytes(16)
    box = struct.pack('>I4s', 8 + len(payload), b'dvvC') + payload
    data[sum(chain[-1]):sum(chain[-1])] = box
    for at, size in chain:
        struct.pack_into('>I', data, at, size + len(box))
    open(path, 'wb').write(data)


main(sys.argv[1], *map(int, sys.argv[2:]))
