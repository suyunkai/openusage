#!/usr/bin/env python3
"""Make the KeyboardShortcuts checkout compile with the Command Line Tools alone.

The CLT ship without the SwiftUI macro plugins (`@Entry`, `#Preview`), which only Xcode has. This spells
out the one `@Entry` and drops the `#Preview` blocks in the editable copy under Packages/. Idempotent.
"""
import pathlib, re, sys

root = pathlib.Path(sys.argv[1]) / "Sources/KeyboardShortcuts"
policy = root / "ConflictPolicy.swift"
s = policy.read_text()
old = """extension EnvironmentValues {
\t@Entry
\tvar keyboardShortcutsConflictPolicy = KeyboardShortcuts.ConflictPolicy.default
}"""
new = """extension EnvironmentValues {
\tvar keyboardShortcutsConflictPolicy: KeyboardShortcuts.ConflictPolicy {
\t\tget { self[KeyboardShortcutsConflictPolicyKey.self] }
\t\tset { self[KeyboardShortcutsConflictPolicyKey.self] = newValue }
\t}
}

private struct KeyboardShortcutsConflictPolicyKey: EnvironmentKey {
\tstatic let defaultValue = KeyboardShortcuts.ConflictPolicy.default
}"""
if old in s:
    policy.write_text(s.replace(old, new))
for f in root.rglob("*.swift"):
    t = f.read_text()
    t2 = re.sub(r"#Preview \{\n.*?\n\}\n\n?", "", t, flags=re.S)
    if t2 != t:
        f.write_text(t2)
left = [str(f) for f in root.rglob("*.swift") if "@Entry" in f.read_text() or "#Preview" in f.read_text()]
if left:
    sys.exit("still uses SwiftUI macros: " + ", ".join(left))
print("==> KeyboardShortcuts patched for the Command Line Tools")
