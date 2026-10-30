"""The verifier's version: the git tree id of scripts/catalog, computed from the files on disk the way
git computes it. Once committed, `git rev-parse <commit>:scripts/catalog` gives the same value, so a
seal can name the exact verifier that checked it without the verifier being committed first."""

import hashlib
import os
import subprocess

from . import config

IGNORED = {"__pycache__", ".DS_Store"}


def _blob(path):
    with open(path, "rb") as f:
        data = f.read()
    return hashlib.sha1(b"blob %d\0" % len(data) + data).digest()


def _tree(path):
    entries = []
    for name in os.listdir(path):
        if name in IGNORED or name.endswith(".pyc"):
            continue
        full = os.path.join(path, name)
        if os.path.isdir(full):
            sha = _tree(full)
            if sha is None:
                continue
            entries.append((name + "/", b"40000", name, sha))
        else:
            mode = b"100755" if os.access(full, os.X_OK) else b"100644"
            entries.append((name, mode, name, _blob(full)))
    if not entries:
        return None
    entries.sort(key=lambda e: e[0].encode())
    body = b"".join(mode + b" " + name.encode() + b"\0" + sha for _, mode, name, sha in entries)
    return hashlib.sha1(b"tree %d\0" % len(body) + body).digest()


def tree_id():
    return _tree(config.CATALOG_SCRIPTS).hex()


def dirty():
    """True when scripts/catalog differs from HEAD (the id then names files not yet committed)."""
    try:
        out = subprocess.run(["git", "-C", config.REPO, "status", "--porcelain", "--", "scripts/catalog"],
                             capture_output=True, text=True, check=True).stdout
        return bool(out.strip())
    except (OSError, subprocess.CalledProcessError):
        return True
