#!/usr/bin/env python3
"""Bounded, read-only NTFS checker for the crash model, independent of libntfs.

This is an exercised-feature oracle, not chkdsk or a repair tool. Supports the
512-byte-sector, uncompressed, single-extent fixtures used by this suite. Other
geometry/attribute-list extents fail closed. Non-$I30 system index ordering,
security descriptors, the journal, and recovery/repair are outside its scope.
"""
import argparse
import json
import os
import stat
import struct

MAX_IMAGE = 128 << 20
MAX_MFT = 16 << 20
MAX_STREAM = 8 << 20
MAX_RECORDS = 16384
MAX_ERRORS = 64
DATA, BITMAP, INDEX_ROOT, INDEX_ALLOC, FILE_NAME = 0x80, 0xB0, 0x90, 0xA0, 0x30


class Invalid(Exception):
    pass


def need(ok, message):
    if not ok:
        raise Invalid(message)


def uint(data, offset, size=4):
    need(0 <= offset <= len(data) - size, "field_bounds")
    return int.from_bytes(data[offset:offset + size], "little")


def bit(data, number):
    need(0 <= number < len(data) * 8, "bitmap_bounds")
    return bool(data[number // 8] & (1 << (number % 8)))


def fixed(data, magic):
    need(len(data) >= 512 and len(data) % 512 == 0, "mst_length")
    need(data[:4] == magic, "mst_magic:" + magic.decode())
    off, count = uint(data, 4, 2), uint(data, 6, 2)
    need(count == len(data) // 512 + 1 and 8 <= off and off + count * 2 <= 510, "mst_usa_bounds")
    output = bytearray(data)
    for i in range(1, count):
        end = i * 512 - 2
        need(data[end:end + 2] == data[off:off + 2], "mst_torn:" + magic.decode())
        output[end:end + 2] = data[off + i * 2:off + i * 2 + 2]
    return bytes(output)


class Image:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            st = os.fstat(self.fd)
            need(stat.S_ISREG(st.st_mode) and 512 <= st.st_size <= MAX_IMAGE, "regular_bounded_image")
            self.size = st.st_size
            boot = self.read(0, 512)
            need(boot[3:11] == b"NTFS    " and boot[510:512] == b"\x55\xaa", "boot_signature")
            need(uint(boot, 11, 2) == 512, "unsupported:sector_size")
            self.cluster = boot[13] * 512
            need(512 <= self.cluster <= 65536 and self.cluster & (self.cluster - 1) == 0, "cluster_size")
            self.clusters = uint(boot, 40, 8) * 512 // self.cluster
            need(0 < self.clusters * self.cluster <= self.size, "volume_bounds")
            code = struct.unpack_from("b", boot, 64)[0]
            need(-16 <= code < 128 and code != 0, "record_size_code")
            self.record_size = (1 << -code) if code < 0 else code * self.cluster
            need(512 <= self.record_size <= 65536 and self.record_size % 512 == 0, "record_size")
            self.mft_lcn = uint(boot, 48, 8)
            self.errors, self.records, self.paths = [], {}, {}
            self.owners, self.unowned = {}, []
            self.nodes = 0
        except BaseException:
            os.close(self.fd)
            raise

    def close(self):
        os.close(self.fd)

    def read(self, offset, length):
        need(0 <= length <= MAX_MFT and 0 <= offset <= self.size - length, "read_bounds")
        data = os.pread(self.fd, length, offset)
        need(len(data) == length, "short_image_read")
        return data

    def issue(self, code, **fields):
        need(len(self.errors) < MAX_ERRORS, "error_limit")
        self.errors.append({"code": code, **fields})

    def attribute_encoding(self, raw):
        """The ordinary crash oracle deliberately rejects compressed data."""
        need(not uint(raw, 12, 2) & 0x4001, "unsupported:compressed_or_encrypted")
        return {}

    def attrs(self, record):
        used, pos = uint(record, 24), uint(record, 20, 2)
        need(48 <= pos < used <= len(record), "record_attribute_bounds")
        result = []
        while pos + 4 <= used:
            typ = uint(record, pos)
            if typ == 0xFFFFFFFF:
                return result
            need(len(result) < 256, "attribute_limit")
            length = uint(record, pos + 4)
            need(length >= 24 and length % 8 == 0 and length <= used - pos, "attribute_bounds")
            raw = record[pos:pos + length]
            nonresident, name_len, name_off = raw[8], raw[9], uint(raw, 10, 2)
            need(nonresident in (0, 1), "attribute_residency")
            need(name_len == 0 or 16 <= name_off <= length - name_len * 2, "attribute_name_bounds")
            name = raw[name_off:name_off + name_len * 2].decode("utf-16-le") if name_len else ""
            encoding = self.attribute_encoding(raw)
            need(typ != 0x20, "unsupported:attribute_list")
            attr = {"type": typ, "name": name, "nonresident": bool(nonresident), "pos": pos, **encoding}
            if nonresident:
                need(length >= 64 and uint(raw, 16, 8) == 0, "unsupported:attribute_extent")
                size, initialized, allocated = uint(raw, 48, 8), uint(raw, 56, 8), uint(raw, 40, 8)
                need(initialized <= size and allocated % self.cluster == 0, "attribute_sizes")
                off, vcn, lcn, runs = uint(raw, 32, 2), 0, 0, []
                need(64 <= off < length, "runlist_offset")
                while off < length and raw[off]:
                    widths = raw[off]; off += 1
                    nlen, nloc = widths & 15, widths >> 4
                    need(1 <= nlen <= 8 and nloc <= 8 and off + nlen + nloc <= length, "runlist_encoding")
                    count = uint(raw, off, nlen); off += nlen
                    need(0 < count <= self.clusters and len(runs) < 4096, "runlist_count")
                    physical = None
                    if nloc:
                        lcn += int.from_bytes(raw[off:off + nloc], "little", signed=True)
                        physical = lcn
                        need(0 <= lcn <= self.clusters - count, "runlist_lcn_bounds")
                    off += nloc
                    runs.append((vcn, count, physical)); vcn += count
                    need(vcn <= self.clusters, "runlist_vcn_bounds")
                need(off < length and raw[off] == 0, "runlist_terminator")
                need(size <= vcn * self.cluster and (vcn == 0 or uint(raw, 24, 8) + 1 == vcn), "runlist_size")
                attr.update(size=size, initialized=initialized, allocated=allocated, runs=runs)
            else:
                size, off = uint(raw, 16), uint(raw, 20, 2)
                need(24 <= off <= length - size, "resident_bounds")
                attr.update(size=size, initialized=size, data=raw[off:off + size])
            result.append(attr); pos += length
        raise Invalid("attribute_terminator")

    @staticmethod
    def attr(record, typ, name="", optional=False):
        matches = [a for a in record["attrs"] if a["type"] == typ and a["name"] == name]
        need(len(matches) <= 1 and (optional or len(matches) == 1), "attribute_missing_or_duplicate")
        return matches[0] if matches else None

    def stream(self, attr, limit=MAX_STREAM):
        size = attr["size"]
        need(size <= limit, "stream_limit")
        if not attr["nonresident"]:
            return attr["data"]
        result = bytearray(size)
        for vcn, count, lcn in attr["runs"]:
            start = vcn * self.cluster
            length = min(count * self.cluster, max(0, attr["initialized"] - start))
            if lcn is not None and length:
                result[start:start + length] = self.read(lcn * self.cluster, length)
        return bytes(result)

    def physical(self, attr, offset):
        need(attr["nonresident"], "physical_resident")
        for vcn, count, lcn in attr["runs"]:
            if vcn * self.cluster <= offset < (vcn + count) * self.cluster:
                need(lcn is not None, "physical_sparse")
                return lcn * self.cluster + offset - vcn * self.cluster
        raise Invalid("physical_bounds")

    @staticmethod
    def filename(value):
        need(len(value) >= 66 and len(value) == 66 + value[64] * 2, "filename_bounds")
        need(value[65] <= 3, "filename_namespace")
        return (uint(value, 0, 8), value[66:].decode("utf-16-le"), value[65])

    def scan(self, reserved=()):
        raw0 = self.read(self.mft_lcn * self.cluster, self.record_size)
        zero = {"attrs": self.attrs(fixed(raw0, b"FILE"))}
        self.mft = self.attr(zero, DATA)
        raw = self.stream(self.mft, MAX_MFT)
        count = len(raw) // self.record_size
        need(len(raw) % self.record_size == 0 and 0 < count <= MAX_RECORDS, "mft_record_count")
        bitmap = self.stream(self.attr(zero, BITMAP))
        for ino in range(count):
            data = raw[ino * self.record_size:(ino + 1) * self.record_size]
            active = bool(uint(data, 22, 2) & 1)
            if not bit(bitmap, ino) and not active:
                continue
            # mkntfs reserves records 16..23 without marking the record in use.
            if bit(bitmap, ino) != active and not (16 <= ino < 24 and not active):
                self.issue("mft_bitmap_mismatch", ino=ino, active=active)
            if not active:
                continue
            try:
                data = fixed(data, b"FILE")
                need(uint(data, 32, 8) == 0, "unsupported:extension_record")
                attrs = self.attrs(data)
                self.records[ino] = {"attrs": attrs, "seq": uint(data, 16, 2), "links": uint(data, 18, 2),
                                     "dir": bool(uint(data, 22, 2) & 2), "data": data,
                                     "names": [self.filename(a["data"]) for a in attrs if a["type"] == FILE_NAME]}
                for attr in attrs:
                    for _, n, lcn in attr.get("runs", []):
                        if lcn is None:
                            continue
                        for c in range(lcn, lcn + n):
                            if c in self.owners:
                                self.issue("cluster_crosslink", cluster=c, owner=self.owners[c], other=ino)
                            else:
                                self.owners[c] = ino
            except (Invalid, UnicodeError) as exc:
                self.issue(str(exc), ino=ino)
        need(all(i in self.records for i in (0, 1, 5, 6)), "core_record_missing")
        cb = self.stream(self.attr(self.records[6], DATA))
        allowed = set(reserved)
        for c in range(self.clusters):
            if c in self.owners and not bit(cb, c):
                self.issue("referenced_cluster_free", cluster=c, ino=self.owners[c])
            if bit(cb, c) and c not in self.owners:
                self.unowned.append(c)
                if c not in allowed:
                    self.issue("allocated_cluster_unowned", cluster=c)
        mirror = self.stream(self.attr(self.records[1], DATA))
        for i in range(max(4, self.cluster // self.record_size)):
            try:
                m = fixed(mirror[i * self.record_size:(i + 1) * self.record_size], b"FILE")
                need(i in self.records and m == self.records[i]["data"], "mft_mirror_mismatch")
            except Invalid as exc:
                self.issue(str(exc), ino=i)
        indexes = {}
        for ino, record in self.records.items():
            if record["dir"]:
                try:
                    indexes[ino] = self.directory(ino, record)
                except (Invalid, UnicodeError) as exc:
                    self.issue(str(exc), ino=ino)
        indexed = set()
        for parent, entries in indexes.items():
            for ref, name in entries:
                ino, seq = ref & ((1 << 48) - 1), ref >> 48
                target = self.records.get(ino)
                if not target or target["seq"] != seq:
                    self.issue("index_target_invalid", parent=parent, ino=ino, name=name[1]); continue
                expected_parent = parent | (self.records[parent]["seq"] << 48)
                if name[0] != expected_parent or name not in target["names"]:
                    self.issue("index_filename_mismatch", parent=parent, ino=ino, name=name[1])
                key = (ino, *name)
                if key in indexed:
                    self.issue("index_duplicate", parent=parent, ino=ino, name=name[1])
                indexed.add(key)
        for ino, record in self.records.items():
            for name in record["names"]:
                if (ino, *name) not in indexed:
                    self.issue("filename_not_indexed", ino=ino, name=name[1])
            # NTFS link count counts FILE_NAME attributes, including DOS names.
            if record["names"] and record["links"] != len(record["names"]):
                self.issue("link_count_mismatch", ino=ino, links=record["links"], names=len(record["names"]))
        todo, visited = [(5, "")], set()
        while todo:
            ino, path = todo.pop()
            if ino in visited:
                self.issue("directory_cycle", ino=ino); continue
            visited.add(ino)
            for ref, name in indexes.get(ino, []):
                target = ref & ((1 << 48) - 1)
                if name[1] == ".":
                    continue
                newpath = path + "/" + name[1]
                need(len(newpath) < 4096 and len(self.paths) < MAX_RECORDS * 4, "namespace_limit")
                self.paths[newpath] = target
                if target in self.records and self.records[target]["dir"]:
                    todo.append((target, newpath))
        return self

    def directory(self, ino, record):
        root = self.stream(self.attr(record, INDEX_ROOT, "$I30"))
        need(len(root) >= 32 and uint(root, 0) == FILE_NAME, "index_root_type")
        blocksize = uint(root, 8)
        need(512 <= blocksize <= 65536 and blocksize & (blocksize - 1) == 0, "index_block_size")
        allocation = self.attr(record, INDEX_ALLOC, "$I30", optional=True)
        bitmap = self.attr(record, BITMAP, "$I30", optional=True)
        blocks = self.stream(allocation) if allocation else b""
        bits = self.stream(bitmap) if bitmap else b""
        need(len(blocks) % blocksize == 0, "index_allocation_size")
        seen, entries, pending = set(), [], [(root, 16)]
        while pending:
            data, base = pending.pop()
            pos, end, allocated = uint(data, base), uint(data, base + 4), uint(data, base + 8)
            need(16 <= pos <= end <= allocated <= len(data) - base, "index_header_bounds")
            pos += base; end += base
            terminated = False
            while pos < end:
                need(pos + 16 <= end, "index_entry_header")
                ref, length, keysize, flags = uint(data, pos, 8), uint(data, pos + 8, 2), uint(data, pos + 10, 2), uint(data, pos + 12, 2)
                need(length >= 16 and length % 8 == 0 and length <= end - pos and flags <= 3, "index_entry_bounds")
                need(keysize <= length - 16 - (8 if flags & 1 else 0), "index_key_bounds")
                if flags & 1:
                    vcn = uint(data, pos + length - 8, 8)
                    off = vcn * (self.cluster if self.cluster <= blocksize else 512)
                    need(off % blocksize == 0 and off <= len(blocks) - blocksize, "index_child_bounds")
                    n = off // blocksize
                    need(n not in seen and bit(bits, n), "index_child_bitmap_or_cycle")
                    seen.add(n); self.nodes += 1
                    need(self.nodes < MAX_RECORDS, "index_node_limit")
                    child = fixed(blocks[off:off + blocksize], b"INDX")
                    need(uint(child, 16, 8) == vcn, "index_vcn_mismatch")
                    pending.append((child, 24))
                if flags & 2:
                    need(keysize == 0 and pos + length == end, "index_end_entry")
                    terminated = True; break
                name = self.filename(data[pos + 16:pos + 16 + keysize])
                entries.append((ref, name)); pos += length
                need(len(entries) <= MAX_RECORDS * 4, "index_entry_limit")
            need(terminated, "index_terminator")
        for n in range(len(blocks) // blocksize):
            if bit(bits, n) and n not in seen:
                self.issue("index_node_unreachable", ino=ino, node=n)
        return entries

    def file(self, path, stream=""):
        ino = self.paths.get(path)
        need(ino in self.records, "path_missing:" + path)
        return self.stream(self.attr(self.records[ino], DATA, stream))

    def result(self):
        return {"ok": not self.errors, "errors": self.errors, "records": len(self.records),
                "index_nodes": self.nodes, "clusters_owned": len(self.owners), "unowned": self.unowned,
                "paths": {k: v for k, v in self.paths.items() if k.startswith("/crash-model")}}


def inspect(path, reserved=()):
    image = None
    try:
        image = Image(path)
        image.scan(reserved)
        return image.result()
    except (Invalid, UnicodeError) as exc:
        return {"ok": False, "errors": [{"code": str(exc)}] + (image.errors if image else [])}
    finally:
        if image:
            image.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image")
    parser.add_argument("--reserved", type=int, nargs="*", default=[])
    args = parser.parse_args()
    result = inspect(args.image, args.reserved)
    print(json.dumps(result, indent=2, sort_keys=True))
    raise SystemExit(0 if result["ok"] else 1)
