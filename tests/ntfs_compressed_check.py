#!/usr/bin/env python3
"""Independent bounded LZNT1/data-layout oracle for the compressed fixtures.

Reuses the ordinary oracle's MST/runlist/bitmap/namespace checks, whose default
still rejects compression. Supports single-extent DATA (named or unnamed), unit 4, clusters
<=4 KiB, images <=128 MiB and streams <=8 MiB. Not chkdsk or Windows acceptance.
LZNT1 rules: Microsoft MS-XCA 2.5.1.2, 2.5.3 and 3.3:
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-xca/cba0fa15-bd62-4eda-8838-8fc7ab406df1
https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-xca/b1ba6d34-499c-4017-ab0c-fe2daee93efc
"""
from ntfs_image_check import DATA, MAX_STREAM, Image, Invalid, need, uint


def lznt1(data, limit=65536):
    """Decode at most one NTFS unit, independently of libntfs; no native calls."""
    need(0 < limit <= 65536 and limit % 4096 == 0, "lznt1_output_limit")
    need(len(data) <= 65536, "lznt1_input_limit")
    output, offset = bytearray(), 0
    while offset < len(data):
        header = uint(data, offset, 2)
        offset += 2
        if header == 0:
            break
        need(header & 0x7000 == 0x3000, "lznt1_signature")
        end = offset + (header & 0xFFF) + 1
        need(end <= len(data), "lznt1_chunk_bounds")
        chunk = bytearray()
        if not header & 0x8000:
            chunk.extend(data[offset:end])
            offset = end
        while offset < end:
            flags = data[offset]
            offset += 1
            for bit in range(8):
                if offset == end:
                    break
                if flags & (1 << bit):
                    need(offset + 2 <= end, "lznt1_token_bounds")
                    token = uint(data, offset, 2)
                    offset += 2
                    shift, mask, position = 12, 0xFFF, len(chunk) - 1
                    while position >= 16:
                        shift -= 1
                        mask >>= 1
                        position >>= 1
                    distance, length = (token >> shift) + 1, (token & mask) + 3
                    need(distance <= len(chunk), "lznt1_backreference")
                    need(length <= 4096 - len(chunk), "lznt1_expansion")
                    for _ in range(length):
                        chunk.append(chunk[-distance])
                else:
                    need(len(chunk) < 4096, "lznt1_literal_limit")
                    chunk.append(data[offset])
                    offset += 1
        need(0 < len(chunk) <= 4096 and len(output) + 4096 <= limit, "lznt1_chunk_limit")
        output.extend(chunk)
        output.extend(bytes(4096 - len(chunk)))
    output.extend(bytes(limit - len(output)))
    return bytes(output)


class CompressedImage(Image):
    def attribute_encoding(self, raw):
        flags = uint(raw, 12, 2)
        need(not flags & 0x4000, "unsupported:encrypted")
        mode = flags & 0xFF
        need(mode in (0, 1), "unsupported:compression_mode")
        if mode:
            need(uint(raw, 0) == DATA, "unsupported:compressed_stream")
            need(self.cluster <= 4096, "unsupported:compression_cluster")
        fields = {"compression": mode, "flags": flags}
        if mode and raw[8]:
            need(len(raw) >= 72, "compressed_header")
            need(uint(raw, 34, 2) == 4, "unsupported:compression_unit")
            fields.update(unit=16 * self.cluster, compressed_size=uint(raw, 64, 8))
        return fields

    def attrs(self, record):
        attrs = super().attrs(record)
        for attr in attrs:
            if attr["compression"] and attr["nonresident"]:
                physical = sum(n for _, n, lcn in attr["runs"] if lcn is not None) * self.cluster
                coverage = sum(n for _, n, _ in attr["runs"]) * self.cluster
                need(attr["compressed_size"] == physical, "compressed_size_mismatch")
                need(attr["allocated"] == coverage and coverage % attr["unit"] == 0,
                     "compressed_allocation_alignment")
        return attrs

    def units(self, attr):
        need(attr["size"] <= MAX_STREAM, "compressed_stream_limit")
        count = (attr["size"] + attr["unit"] - 1) // attr["unit"]
        for unit in range(count):
            first = unit * 16
            clusters = []
            for vcn in range(first, first + 16):
                matches = [(start, lcn) for start, n, lcn in attr["runs"] if start <= vcn < start + n]
                need(len(matches) == 1, "compressed_unit_coverage")
                start, lcn = matches[0]
                clusters.append(None if lcn is None else lcn + vcn - start)
            physical = [c for c in clusters if c is not None]
            need(clusters[:len(physical)] == physical and all(c is None for c in clusters[len(physical):]),
                 "compressed_nonterminal_hole")
            yield physical

    def stream(self, attr, limit=MAX_STREAM):
        if not attr.get("compression") or not attr["nonresident"]:
            return super().stream(attr, limit)
        need(attr["size"] <= min(limit, MAX_STREAM), "compressed_stream_limit")
        result = bytearray()
        for clusters in self.units(attr):
            data = b"".join(self.read(c * self.cluster, self.cluster) for c in clusters)
            if not clusters:
                data = bytes(attr["unit"])
            elif len(clusters) < 16:
                data = lznt1(data, attr["unit"])
            result.extend(data)
        result = result[:attr["size"]]
        # NTFS initialized_size, rather than encoded allocation, controls visible zeros.
        result[attr["initialized"]:] = bytes(attr["size"] - attr["initialized"])
        return bytes(result)

    def layout(self, attr):
        if not attr["nonresident"]:
            return ["resident"]
        if not attr.get("compression"):
            return ["ordinary"]
        return ["raw" if len(c) == 16 else "lznt1" if c else "hole" for c in self.units(attr)]


def self_test():
    # Independently constructed literals and overlapping matches, plus chunk reset.
    need(lznt1(bytes.fromhex("03b00241fc0f"), 4096) == b"A" * 4096, "lznt1_repeat_vector")
    literal = b"\x02\x30XYZ"
    need(lznt1(literal, 4096) == b"XYZ" + bytes(4093), "lznt1_literal_vector")
    need(lznt1(literal * 2, 8192) == (b"XYZ" + bytes(4093)) * 2, "lznt1_chunk_reset")
    for bad in [b"\x01", b"\x01\x10xx", b"\x03\xb0\x01\x00\x00\x00",
                b"\x03\xb0\x02A\xff\x0f", b"\x03\xb0\x00A"]:
        try:
            lznt1(bad, 4096)
        except Invalid:
            pass
        else:
            raise AssertionError("accepted invalid LZNT1: " + bad.hex())
    return 8


if __name__ == "__main__":
    print("PASS:", self_test(), "independent decoder controls")
