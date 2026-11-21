#!/usr/bin/env python3
"""Let a restored SwiftPM build be reused on a fresh CI checkout.

SwiftPM decides what to recompile from each source file's modification time.
A fresh checkout stamps every file with the current time, so a restored
`.build` is discarded and everything compiles again. This tool keeps a
manifest next to the cached build that records, for every tracked file, its
git mode, its blob id, and the modification time the cached build saw.

`sync <manifest>` gives a file its recorded time only when its mode and blob
are identical to the recorded ones, so its content is what the cached build
compiled. Every new or changed file keeps its checkout time, which is newer
than anything in the cache, and is compiled again. It then rewrites the
manifest for the current tree so a cache saved after this build stays
consistent. A missing or unreadable manifest restores nothing.
"""
import json
import os
import subprocess
import sys

MANIFEST_VERSION = 1


def tracked_files(root):
    listing = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root)
    for record in listing.split(b'\0'):
        if not record:
            continue
        meta, path = record.split(b'\t', 1)
        mode, blob, stage = meta.split()
        # Skip submodules and unmerged entries: neither is one checked-out blob.
        if mode == b'160000' or stage != b'0':
            continue
        yield os.fsdecode(path), f'{mode.decode()} {blob.decode()}'


def load_manifest(manifest_path):
    try:
        with open(manifest_path, encoding='utf-8') as handle:
            manifest = json.load(handle)
        if manifest.get('version') != MANIFEST_VERSION:
            return {}
        files = manifest['files']
        return files if isinstance(files, dict) else {}
    except (OSError, ValueError, KeyError, AttributeError):
        return {}


def sync(root, manifest_path):
    recorded = load_manifest(manifest_path)
    current = {}
    reused = 0
    for path, identity in tracked_files(root):
        full_path = os.path.join(root, path)
        try:
            entry = recorded.get(path)
            if (isinstance(entry, list) and len(entry) == 2
                    and entry[0] == identity and isinstance(entry[1], int)):
                os.utime(full_path, ns=(entry[1], entry[1]), follow_symlinks=False)
                reused += 1
            current[path] = [identity, os.lstat(full_path).st_mtime_ns]
        except OSError:
            continue  # Tracked but absent from the working tree.
    os.makedirs(os.path.dirname(os.path.abspath(manifest_path)), exist_ok=True)
    temporary_path = f'{manifest_path}.tmp'
    with open(temporary_path, 'w', encoding='utf-8') as handle:
        json.dump({'version': MANIFEST_VERSION, 'files': current}, handle)
    os.replace(temporary_path, manifest_path)
    return reused, len(current) - reused


def main(arguments):
    if len(arguments) != 2 or arguments[0] != 'sync':
        print('usage: ci_source_mtimes.py sync <manifest>', file=sys.stderr)
        return 2
    root = subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()
    reused, fresh = sync(root, arguments[1])
    print(f'Reused the cached build time for {reused} unchanged files; '
          f'{fresh} new or changed files keep their checkout time.')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
