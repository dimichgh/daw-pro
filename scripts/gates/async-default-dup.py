#!/usr/bin/env python3
"""Async-closure duplicate gate (2026-10-05, W7-STALL round 2).

Swift 6.3.3 compiles an async closure written as a DEFAULT ARGUMENT twice: in its own
module, and again in every module that calls the function without that argument. Both
copies share ONE weak symbol, but each object file's "async function pointer" record
(`...Tu`: a 32-bit code offset + a 32-bit context size) carries the size ITS copy needs,
and the two can differ (80 vs 64, 48 vs 32). The linker may keep one copy's code with the
other copy's record; the caller then allocates too little and the task allocator aborts
with "freed pointer was not the last allocation". A green test run proves nothing here:
whether a mismatched call aborts depends on where it lands in task memory.

This gate reads the build itself. For every weak `...Tu` symbol DEFINED in more than one
object file of the same linked product (that product's `Objects.LinkFileList`, so stale
objects from deleted files are ignored), it compares the context sizes:
  - different sizes  -> FAIL (exit 1): the link can pair them wrongly;
  - identical sizes  -> WARN only: a latent duplicate, one changed caller away from a FAIL.
Exit 3 if the scan saw no objects or no weak async records at all (the tool is not
looking, so its silence would mean nothing).

Run it on the SAME build folder the test run used, after the run.
usage: async-default-dup.py [build-dir]   (default .build/arm64-apple-macosx/debug)
"""
import os
import re
import subprocess
import sys
from collections import defaultdict

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', '..', '.build', 'arm64-apple-macosx', 'debug')
root = os.path.realpath(root)

NM_LINE = re.compile(r'^([0-9a-f]+) \((\w+),(\w+)\) (.*?)(_\$s\S*Tu)$')


def link_lists(top):
    """Each linked product's own object list. Duplicates only collide inside ONE link, and
    stale objects from deleted files stay on disk but are in no list."""
    for d in sorted(os.listdir(top)):
        f = os.path.join(top, d, 'Objects.LinkFileList')
        if d.endswith('.product') and os.path.isfile(f):
            with open(f) as fh:
                objs = [l.strip().strip("'\"") for l in fh if l.strip().endswith('.o') or l.strip().endswith(".o'")]
            yield d[:-len('.product')], objs


def section_bytes(path, seg, sect, cache):
    key = (path, seg, sect)
    if key in cache:
        return cache[key]
    out = subprocess.run(['otool', '-s', seg, sect, path], capture_output=True, text=True).stdout
    mem = {}
    for line in out.splitlines():
        m = re.match(r'^([0-9a-f]{8,16})\s+(.*)$', line.strip())
        if not m:
            continue
        base = int(m.group(1), 16)
        offset = 0
        for word in m.group(2).split():
            b = bytes.fromhex(word)
            if len(b) == 4:
                b = b[::-1]  # otool prints arm64 32-bit words as little-endian numbers
            for x in b:
                mem[base + offset] = x
                offset += 1
    cache[key] = mem
    return mem


def context_size(path, seg, sect, addr, cache):
    mem = section_bytes(path, seg, sect, cache)
    rec = bytes(mem.get(addr + k, 0) for k in range(8))
    if not all((addr + k) in mem for k in range(8)):
        return None
    return int.from_bytes(rec[4:8], 'little')


nm_cache = {}


def weak_async_defs(obj):
    if obj not in nm_cache:
        out = subprocess.run(['nm', '-m', obj], capture_output=True, text=True).stdout
        found = []
        for line in out.splitlines():
            m = NM_LINE.match(line)
            if m and 'weak' in m.group(4):
                found.append((m.group(5), m.group(2), m.group(3), int(m.group(1), 16)))
        nm_cache[obj] = found
    return nm_cache[obj]


products = list(link_lists(root))
scanned = 0
weak_records = 0
per_product = {}
for product, objs in products:
    defs = defaultdict(list)  # symbol -> [(object, seg, sect, addr)]
    for obj in objs:
        scanned += 1
        for sym, seg, sect, addr in weak_async_defs(obj):
            weak_records += 1
            defs[sym].append((obj, seg, sect, addr))
    per_product[product] = defs

if not products or scanned == 0 or weak_records == 0:
    print(f'async-default-dup: NOT LOOKING: {len(products)} link lists, {scanned} objects, '
          f'{weak_records} weak async records under {root}')
    sys.exit(3)


def demangle(sym):
    r = subprocess.run(['xcrun', 'swift-demangle', '--simplified', '--compact', sym[1:]], capture_output=True, text=True)
    return (r.stdout.strip() or sym)


cache = {}
demangled = {}


def name(sym):
    if sym not in demangled:
        demangled[sym] = demangle(sym)
    return demangled[sym]


any_fail = False
for product, defs in per_product.items():
    fails, warns = [], []
    for sym, places in sorted(defs.items()):
        if len(places) < 2:
            continue
        sizes = [(context_size(o, sg, sc, a, cache), os.path.relpath(o, root)) for o, sg, sc, a in places]
        (fails if len({z for z, _ in sizes}) > 1 else warns).append((sym, sizes))
    # Identical duplicates are mostly ordinary compiler thunks and specialisations (normal,
    # and harmless while identical). Only a DEFAULT-ARGUMENT closure is named: the latent case.
    named_warns = [(sy, z) for sy, z in warns if 'default argument' in name(sy)]
    print(f'{product}: {len(fails)} DIFFERENT-size duplicates, {len(warns)} identical '
          f'({len(named_warns)} default-argument closures)')
    for label, group in (('FAIL', fails), ('warn', named_warns)):
        for sym, sizes in group:
            print(f'  {label}: {name(sym)}')
            for size, obj in sizes:
                print(f'        contextSize={size}  {obj}')
    any_fail = any_fail or bool(fails)
print(f'async-default-dup: {len(products)} linked products, {scanned} object reads, {weak_records} weak async records')
sys.exit(1 if any_fail else 0)
