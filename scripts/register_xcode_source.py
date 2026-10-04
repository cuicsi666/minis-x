#!/usr/bin/env python3
"""Register new Swift source files with the Xcode project.

WHY THIS EXISTS
---------------
Despite what one might assume from an Xcode 16 project, the *Minis* app target
in this repo does NOT use a PBXFileSystemSynchronizedRootGroup for its sources
(only `Terminal`, `MinisTests` and `MinisUITests` are synchronized root
groups).  Every app source file is an explicit PBXFileReference + PBXBuildFile
entry, so a new .swift file dropped into src/ios/ is **not** compiled until it
is registered.  This script performs the four insertions safely & idempotently.

USAGE
-----
    python3 scripts/register_xcode_source.py Shared/Config/MinisXBundledProviderSeed.swift
    python3 scripts/register_xcode_source.py A.swift B.swift --dry-run
    python3 scripts/register_xcode_source.py A.swift --project /tmp/x/project.pbxproj

Paths are relative to `src/ios` (the directory that contains Minis.xcodeproj).
The file must already exist on disk.  A `.bak` copy of the project file is
written next to it before the first modification.
"""

import argparse
import os
import re
import shutil
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_PROJECT = os.path.join(REPO_ROOT, "src", "ios", "Minis.xcodeproj", "project.pbxproj")
SRC_IOS = os.path.join(REPO_ROOT, "src", "ios")

# Sources build phase of the "Minis" application target.
APP_SOURCES_PHASE = "E51000041"


def gen_id(existing: set) -> str:
    """24 hex chars, unique within the file."""
    import random

    while True:
        candidate = "%024X" % random.getrandbits(96)
        if candidate not in existing:
            existing.add(candidate)
            return candidate


def parse_groups(text: str):
    """Return [(group_id, group_path)] for every PBXGroup that declares a path."""
    groups = []
    for m in re.finditer(
        r"^\t\t([0-9A-Za-z]{6,32}) /\* [^*]* \*/ = \{\n\t\t\tisa = PBXGroup;\n(.*?)\n\t\t\};",
        text,
        re.M | re.S,
    ):
        gid, body = m.group(1), m.group(2)
        pm = re.search(r'^\t\t\tpath = "?([^";]+)"?;', body, re.M)
        if pm:
            groups.append((gid, pm.group(1)))
    return groups


def pick_group(rel_path: str, groups):
    """Longest group-path prefix of rel_path's directory wins."""
    target_dir = os.path.dirname(rel_path)
    best = None
    for gid, gpath in groups:
        if target_dir == gpath or target_dir.startswith(gpath + "/"):
            if best is None or len(gpath) > len(best[1]):
                best = (gid, gpath)
    return best


def register(project_path: str, rel_path: str, dry_run=False) -> bool:
    rel_path = rel_path.replace("\\", "/").lstrip("/")
    abs_path = os.path.join(SRC_IOS, rel_path)
    if not os.path.isfile(abs_path):
        print("  !! missing on disk: %s" % abs_path)
        return False

    text = open(project_path, encoding="utf-8").read()
    base = os.path.basename(rel_path)

    if base in text.split("/* End PBXFileReference section */")[0] and re.search(
        r"/\* %s \*/ = \{isa = PBXFileReference" % re.escape(base), text
    ):
        print("  = already registered: %s" % rel_path)
        return False

    groups = parse_groups(text)
    picked = pick_group(rel_path, groups)
    if picked is None:
        print("  !! no PBXGroup found for %s (create the group first)" % rel_path)
        return False
    group_id, group_path = picked
    child_path = rel_path[len(group_path) + 1:] if group_path else rel_path

    existing_ids = set(re.findall(r"^\t\t([0-9A-Za-z]{6,32}) ", text, re.M))
    build_id = gen_id(existing_ids)
    file_id = gen_id(existing_ids)

    # 1) PBXBuildFile
    anchor = "/* Begin PBXBuildFile section */\n"
    entry = "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (
        build_id, base, file_id, base,
    )
    text = text.replace(anchor, anchor + entry, 1)

    # 2) PBXFileReference
    anchor = "/* Begin PBXFileReference section */\n"
    entry = (
        '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
        'path = "%s"; sourceTree = "<group>"; };\n' % (file_id, base, child_path)
    )
    text = text.replace(anchor, anchor + entry, 1)

    # 3) group children
    m = re.search(
        r"(^\t\t%s /\* [^*]* \*/ = \{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = \(\n)" % group_id,
        text, re.M,
    )
    if not m:
        print("  !! could not open children list of group %s" % group_id)
        return False
    at = m.end()
    text = text[:at] + "\t\t\t\t%s /* %s */,\n" % (file_id, base) + text[at:]

    # 4) Sources phase
    m = re.search(
        r"(^\t\t%s /\* Sources \*/ = \{\n\t\t\tisa = PBXSourcesBuildPhase;\n"
        r"\t\t\tbuildActionMask = \d+;\n\t\t\tfiles = \(\n)" % APP_SOURCES_PHASE,
        text, re.M,
    )
    if not m:
        print("  !! app Sources phase %s not found" % APP_SOURCES_PHASE)
        return False
    at = m.end()
    text = text[:at] + "\t\t\t\t%s /* %s in Sources */,\n" % (build_id, base) + text[at:]

    print("  + %s  (group %s path=%s → stored path=%s)" % (rel_path, group_id, group_path, child_path))
    if not dry_run:
        if not os.path.exists(project_path + ".bak"):
            shutil.copy2(project_path, project_path + ".bak")
        open(project_path, "w", encoding="utf-8").write(text)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="+", help="paths relative to src/ios")
    ap.add_argument("--project", default=DEFAULT_PROJECT)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    changed = 0
    for rel in args.files:
        if register(args.project, rel, args.dry_run):
            changed += 1
    print("%s%d file(s) %s." % ("[dry-run] " if args.dry_run else "", changed,
                                "would be registered" if args.dry_run else "registered"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
