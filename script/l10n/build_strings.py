#!/usr/bin/env python3
"""Writes <app>/Contents/Resources/{en,zh-Hans}.lproj/Localizable.strings.

usage: build_strings.py <Resources dir> [<dir with .stringsdata from swiftc -emit-localized-strings>]

Keys with interpolations are matched against what swiftc extracted, so the format specifiers
(%@, %lld, %lf…) are exactly the ones the code looks up. Without extracted data, %@ is assumed.
"""
import glob, json, os, re, sys, importlib.util

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("zh", os.path.join(here, "zh-Hans.py"))
zh = importlib.util.module_from_spec(spec); spec.loader.exec_module(zh)
T = zh.T

SPEC = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|lf|f|@|lu|u|ll[ux]|x)')

def norm(key):
    return SPEC.sub('{}', key).replace('%%', '%')

def fill(template, specs):
    """Puts the key's specifiers into the translation; positional when reordered or repeated."""
    template = template.replace('%', '%%')
    order = [int(m) for m in re.findall(r'\{(\d+)\}', template)]
    bare = template.count('{}')
    if order:
        out = template
        for i in range(1, len(specs) + 1):
            s = specs[i - 1].lstrip('%')
            s = re.sub(r'^\d+\$', '', s)
            out = out.replace('{%d}' % i, '%%%d$%s' % (i, s))
        return out
    assert bare == len(specs), (template, specs)
    it = iter(specs)
    return re.sub(r'\{\}', lambda _: next(it), template)

def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')

def unesc_py(s):
    # The table writes "\\n" for a newline inside a Swift literal.
    return s.replace('\\n', '\n')

def extracted_keys(d):
    keys = set()
    for f in glob.glob(os.path.join(d, '**', '*.stringsdata'), recursive=True):
        try:
            data = json.load(open(f))
        except Exception:
            continue
        for table in data.get('tables', {}).values():
            for entry in table:
                keys.add(entry.get('key'))
    return {k for k in keys if k}

def main():
    res = sys.argv[1]
    extracted = extracted_keys(sys.argv[2]) if len(sys.argv) > 2 else set()
    by_norm = {}
    for k in extracted:
        by_norm.setdefault(norm(k), set()).add(k)
    entries = {}
    missing = []
    for en, cn in T.items():
        en, cn = unesc_py(en), unesc_py(cn)
        if '{' not in en:
            entries[en] = cn
            continue
        keys = by_norm.get(en) or {en.replace('%', '%%').replace('{}', '%@')}
        for key in keys:
            entries[key] = fill(cn, SPEC.findall(key))
    for k in sorted(extracted):
        if k not in entries and re.search('[A-Za-z]{2,}', k):
            missing.append(k)
    os.makedirs(os.path.join(res, 'zh-Hans.lproj'), exist_ok=True)
    os.makedirs(os.path.join(res, 'en.lproj'), exist_ok=True)
    with open(os.path.join(res, 'zh-Hans.lproj', 'Localizable.strings'), 'w') as f:
        for k in sorted(entries):
            f.write('"%s" = "%s";\n' % (esc(k), esc(entries[k])))
    open(os.path.join(res, 'en.lproj', 'Localizable.strings'), 'w').write('/* English is the source language. */\n')
    print(f"zh-Hans: {len(entries)} entries; extracted keys without a translation: {len(missing)}")
    if missing:
        open(os.path.join(res, '..', '..', '..', 'l10n-missing.txt'), 'w').write('\n'.join(missing) + '\n')

main()
