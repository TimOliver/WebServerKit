#!/usr/bin/env python3
"""Style gate for Sources/, run by Run-Tests.sh ahead of the unit tests. Four rules:

1. clang-format: every file must match the checked-in .clang-format exactly.
2. Pairing: every .m has a matching .h.
3. Nullability: every header carries an NS_ASSUME_NONNULL region.
4. Naming: a method defined in a .m but declared in no header, no in-file @interface, and no
   protocol must be underscore-prefixed (private-method convention).

Exit code is the violation count, so the suite fails fast on any drift.
"""
import glob, os, re, subprocess, sys

violations = []

CLANG_FORMAT = subprocess.run(["xcrun", "--find", "clang-format"], capture_output=True,
                              text=True).stdout.strip() or "clang-format"

sources = sorted(glob.glob("Sources/**/*.[hm]", recursive=True))
real_sources = [p for p in sources if "/include/" not in p]

# 1. Format drift.
for path in real_sources:
    out = subprocess.run([CLANG_FORMAT, "--dry-run", path], capture_output=True, text=True).stderr
    n = out.count("warning:")
    if n:
        violations.append("format drift: %s (%d)" % (path, n))

# 2. .m/.h pairing.
for path in real_sources:
    if path.endswith(".m") and not os.path.exists(path[:-2] + ".h"):
        violations.append("unpaired implementation: %s" % path)

# 3. Nullability regions.
for path in real_sources:
    if path.endswith(".h") and "NS_ASSUME_NONNULL_BEGIN" not in open(path).read():
        violations.append("missing NS_ASSUME_NONNULL region: %s" % path)

# 4. Private-method prefix. Declared selectors come from headers AND in-file @interface blocks
# (category interfaces in .m files declare deliberate internal seams), plus accessor patterns.
declared = set()
for path in sources:
    text = open(path).read()
    if path.endswith(".m"):
        # Only the @interface regions of a .m declare things.
        text = "\n".join(m.group(0) for m in re.finditer(r"@interface.*?@end", text, re.S))
    for m in re.finditer(r"^[-+]\s*\([^)]+\)\s*([a-zA-Z_][a-zA-Z0-9_]*)", text, re.M):
        declared.add(m.group(1))
    for m in re.finditer(r"@property[^;]*?(\w+);", text):
        declared.add(m.group(1))
    for m in re.finditer(r"getter=(\w+)", text):
        declared.add(m.group(1))

SYSTEM = {"init", "dealloc", "initialize", "description", "copyWithZone", "isEqual", "hash",
          "presentedItemURL", "presentedItemOperationQueue", "presentedSubitemDidChangeAtURL",
          "observeValueForKeyPath", "encodeWithCoder", "initWithCoder"}
for path in real_sources:
    if not path.endswith(".m"):
        continue
    text = open(path).read()
    impl = "\n".join(m.group(0) for m in re.finditer(r"@implementation.*?^@end", text, re.S | re.M))
    for m in re.finditer(r"^[-+]\s*\([^)]+\)\s*([a-zA-Z_][a-zA-Z0-9_]*)", impl, re.M):
        sel = m.group(1)
        if sel.startswith("_") or sel in declared or sel in SYSTEM:
            continue
        if re.match(r"^(init|set[A-Z]|is[A-Z])", sel):
            continue
        violations.append("private method missing _ prefix: %s -%s" % (path, sel))

for v in violations:
    print("LINT: " + v)
print("lint: %d violation(s) across %d files" % (len(violations), len(real_sources)))
sys.exit(min(len(violations), 100))
