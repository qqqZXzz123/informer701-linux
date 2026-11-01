#!/usr/bin/env python3
"""Generate the DTB variants for the Informer 701 (N708H6, Allwinner A10)
from the decompiled base device tree (/tmp/w/base.dts).

Every variant is checked after generation: the script refuses to write a .dts
whose node properties do not match what the boot menu claims.

Variants
--------
  informer.dtb  base tree, unmodified (cpufreq-dt active, full OPP table)
  pinned.dtb    one OPP entry only (1008 MHz @ 1.4 V) - cpufreq registers but
                can never switch frequency, so pll-core is not reprogrammed live
  nocpufreq.dtb no OPP table - cpufreq-dt does not probe at all
  safe.dtb      no OPP, no cpu-supply, no thermal-zones, PMIC/LRADC/RTP off
  noaxp.dtb     PMIC off, OPP table kept
  nommc.dtb     rescue: SD controller off, cpufreq off, PMIC reachable
  wdt.dtb       base + watchdog explicitly enabled
"""
import re
import sys

# usage: mkdtb-variants.py [base.dts] [outdir]
SRC = sys.argv[1] if len(sys.argv) > 1 else '/tmp/w/base.dts'
OUTDIR = sys.argv[2] if len(sys.argv) > 2 else '/tmp/w'
OUT = OUTDIR + '/%s.dts'


# --------------------------------------------------------------------------
# generic helpers over a decompiled (dtc -I dtb -O dts) source
# --------------------------------------------------------------------------
def find_node(text, header, start=0):
    """Locate 'header {' and return (i, brace_open, brace_close)."""
    i = text.index(header, start)
    j = text.index('{', i)
    depth = 0
    k = j
    while k < len(text):
        if text[k] == '{':
            depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0:
                return i, j, k
        k += 1
    raise RuntimeError('unbalanced braces at %s' % header)


def direct_props(text, j, k):
    """Yield (start, end) spans of property statements at depth 1 of a node."""
    depth = 0
    p = j + 1
    stmt = None
    out = []
    while p < k:
        c = text[p]
        if c == '{':
            depth += 1
            stmt = None
        elif c == '}':
            depth -= 1
            stmt = None
        elif depth == 0 and stmt is None and not c.isspace():
            stmt = p
        elif depth == 0 and c == ';' and stmt is not None:
            out.append((stmt, p + 1))
            stmt = None
        p += 1
    return out


def set_status(text, header, val):
    i, j, k = find_node(text, header)
    for (s, e) in direct_props(text, j, k):
        if text[s:e].lstrip().startswith('status'):
            return text[:s] + 'status = "%s";' % val + text[e:]
    return text[:j + 1] + '\n\t\t\tstatus = "%s";' % val + text[j + 1:]


def drop_prop(text, header, prop):
    i, j, k = find_node(text, header)
    for (s, e) in direct_props(text, j, k):
        t = text[s:e].lstrip()
        if t.startswith(prop + ' ') or t.startswith(prop + '='):
            return text[:s] + text[e:]
    raise RuntimeError('property %s not found in %s' % (prop, header))


def replace_prop(text, header, prop, newvalue):
    i, j, k = find_node(text, header)
    for (s, e) in direct_props(text, j, k):
        t = text[s:e].lstrip()
        if t.startswith(prop + ' ') or t.startswith(prop + '='):
            return text[:s] + '%s = %s;' % (prop, newvalue) + text[e:]
    raise RuntimeError('property %s not found in %s' % (prop, header))


def drop_node(text, header):
    i, j, k = find_node(text, header)
    e = k + 1
    if e < len(text) and text[e] == ';':
        e += 1
    ls = text.rfind('\n', 0, i) + 1
    return text[:ls] + text[e:].lstrip('\n')


def set_model(text, model):
    i, j, k = find_node(text, 'compatible = ', 0)
    # the model property lives at depth 1 of the root node
    j = text.index('{')
    depth = 0
    p = j
    while p < len(text):
        if text[p] == '{':
            depth += 1
        elif text[p] == '}':
            depth -= 1
            if depth == 0:
                k = p
                break
        p += 1
    for (s, e) in direct_props(text, j, k):
        if text[s:e].lstrip().startswith('model'):
            return text[:s] + 'model = "%s";' % model + text[e:]
    raise RuntimeError('model property not found')


def add_alias(text, name, path):
    """Deterministic adapter numbering, e.g. /dev/i2c-0 == TWI0 == AXP209."""
    i, j, k = find_node(text, 'aliases {')
    for (s, e) in direct_props(text, j, k):
        if text[s:e].lstrip().startswith(name + ' '):
            return text
    return text[:j + 1] + '\n\t\t%s = "%s";' % (name, path) + text[j + 1:]


def check(text, header, want_status=None, want_no_props=(), want_props=()):
    i, j, k = find_node(text, header)
    props = [text[s:e].strip() for (s, e) in direct_props(text, j, k)]
    st = None
    for p in props:
        if p.startswith('status'):
            st = p
    for wp in want_no_props:
        assert not any(p.startswith(wp) for p in props), \
            '%s still has %s' % (header, wp)
    for wp in want_props:
        assert any(p.startswith(wp) for p in props), \
            '%s is missing %s (has: %s)' % (header, wp, props)
    if want_status:
        assert st and want_status in st, '%s status = %r' % (header, st)
    return props


def write(name, text):
    path = OUT % name
    open(path, 'w').write(text)
    print('  wrote %s (%d bytes)' % (path, len(text)))


# --------------------------------------------------------------------------
# base tree: add i2c aliases so /dev/i2c-0 is always TWI0 (the AXP209 bus)
# --------------------------------------------------------------------------
base = open(SRC).read()
print('variants from %s -> %s' % (SRC, OUTDIR))
base = add_alias(base, 'i2c0', '/soc/i2c@1c2ac00')
base = add_alias(base, 'i2c1', '/soc/i2c@1c2b000')
base = add_alias(base, 'i2c2', '/soc/i2c@1c2b400')
check(base, 'aliases {', want_props=('i2c0 ', 'i2c1 ', 'i2c2 '))

OPP_SINGLE = '<0xf6180 0x155cc0>'      # 1008000 kHz, 1400000 uV


# ------------------------------------------------------------------ informer
write('base', base)

# -------------------------------------------------------------------- pinned
t = base
t = replace_prop(t, 'cpu@0 {', 'operating-points', OPP_SINGLE)
t = drop_node(t, 'thermal-zones {')
t = set_model(t, 'Informer 701 (N708H6) - pinned 1008 MHz')
assert 'thermal-zones' not in t
check(t, 'cpu@0 {', want_props=('operating-points = %s' % OPP_SINGLE, 'cpu-supply'))
check(t, 'pmic@34 {')
check(t, 'mmc@1c0f000 {', 'okay')
check(t, 'lradc@1c22800 {', 'okay')
write('pinned', t)

# ------------------------------------------------------------------ flatvolt
# Две точки OPP, но ОДИНАКОВОЕ напряжение 1.4 В: переход 1008 <-> 912 МГц
# не трогает регулятор вообще. Если плата на этом виснет - убивает сама
# перестройка pll-core на ходу, а не смена VDD-CPU.
t = base
t = replace_prop(t, 'cpu@0 {', 'operating-points',
                 '<0xf6180 0x155cc0 0xdea80 0x155cc0>')
t = drop_node(t, 'thermal-zones {')
t = set_model(t, 'Informer 701 (N708H6) - flat 1.4V, 1008/912 MHz')
assert 'thermal-zones' not in t
check(t, 'cpu@0 {', want_props=('operating-points = <0xf6180 0x155cc0 0xdea80 0x155cc0>',
                                'cpu-supply'))
check(t, 'pmic@34 {')
write('flatvolt', t)

# ----------------------------------------------------------------- nocpufreq
t = base
t = drop_prop(t, 'cpu@0 {', 'operating-points')
t = drop_node(t, 'thermal-zones {')
t = set_model(t, 'Informer 701 (N708H6) - no cpufreq')
assert 'thermal-zones' not in t
check(t, 'cpu@0 {', want_no_props=('operating-points',))
check(t, 'pmic@34 {')
write('nocpufreq', t)

# ---------------------------------------------------------------------- safe
t = base
t = drop_prop(t, 'cpu@0 {', 'operating-points')
t = drop_prop(t, 'cpu@0 {', 'cpu-supply')
t = drop_node(t, 'thermal-zones {')
t = set_status(t, 'pmic@34 {', 'disabled')
t = set_status(t, 'lradc@1c22800 {', 'disabled')
t = set_status(t, 'rtp@1c25000 {', 'disabled')
t = set_model(t, 'Informer 701 (N708H6) - safe')
assert 'thermal-zones' not in t
check(t, 'pmic@34 {', 'disabled')
check(t, 'lradc@1c22800 {', 'disabled')
check(t, 'rtp@1c25000 {', 'disabled')
check(t, 'cpu@0 {', want_no_props=('operating-points', 'cpu-supply'))
check(t, 'mmc@1c0f000 {', 'okay')
write('safe', t)

# --------------------------------------------------------------------- noaxp
t = base
t = drop_node(t, 'thermal-zones {')
t = set_status(t, 'pmic@34 {', 'disabled')
t = set_status(t, 'lradc@1c22800 {', 'disabled')
t = set_model(t, 'Informer 701 (N708H6) - no PMIC')
assert 'thermal-zones' not in t
check(t, 'pmic@34 {', 'disabled')
check(t, 'cpu@0 {', want_props=('operating-points',))
write('noaxp', t)

# --------------------------------------------------------------------- nommc
t = base
t = drop_prop(t, 'cpu@0 {', 'operating-points')
t = drop_prop(t, 'cpu@0 {', 'cpu-supply')
t = drop_node(t, 'thermal-zones {')
t = set_status(t, 'mmc@1c0f000 {', 'disabled')
t = set_status(t, 'lradc@1c22800 {', 'disabled')
t = set_status(t, 'rtp@1c25000 {', 'disabled')
t = set_model(t, 'Informer 701 (N708H6) - rescue (mmc off)')
check(t, 'mmc@1c0f000 {', 'disabled')
check(t, 'pmic@34 {')                       # PMIC stays reachable via i2c
check(t, 'cpu@0 {', want_no_props=('operating-points', 'cpu-supply'))
write('nommc', t)

# ----------------------------------------------------------------------- wdt
t = base
t = set_status(t, 'watchdog@1c20c90 {', 'okay')
t = set_model(t, 'Informer 701 (N708H6) - watchdog diag')
check(t, 'watchdog@1c20c90 {', 'okay')
write('wdt', t)

print('all variants generated and verified')
