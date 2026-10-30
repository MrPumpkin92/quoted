"""Paths and thresholds."""

import hashlib
import json
import os
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG_SCRIPTS = os.path.dirname(HERE)            # scripts/catalog
REPO = os.path.dirname(os.path.dirname(CATALOG_SCRIPTS))

# Matching thresholds (plan section 4.4). Their hash goes into every result.
THRESHOLDS = {
    "near_high_ratio": 0.85,
    "near_high_coverage": 0.85,
    "near_low_ratio": 0.55,
    "near_low_coverage": 0.6,
    "near_low_block": 3,
    "anchor_max_hits": 200,
    "elision_max_gap_tokens": 150,
    "max_body_chars": 280,
}
THRESHOLDS_SHA = hashlib.sha256(json.dumps(THRESHOLDS, sort_keys=True).encode()).hexdigest()[:12]

THEMES = ["courage", "calm", "time", "love", "nature", "purpose", "self"]
MOODS = ["rousing", "steadying", "consoling", "reflective", "tender", "delight"]

USER_AGENT_FILE = "user_agent.txt"


def data_dir():
    """Committed catalog data: supabase/catalog/ (D9)."""
    return os.path.join(REPO, "supabase", "catalog")


def migrations_dir():
    return os.path.join(REPO, "supabase", "migrations")


def build_dir():
    """Downloads and run output (gitignored). QCAT_BUILD_DIR, else build/catalog in the main
    checkout, so worktrees share one corpus."""
    env = os.environ.get("QCAT_BUILD_DIR")
    if env:
        return env
    try:
        common = subprocess.run(["git", "-C", REPO, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, check=True).stdout.strip()
        main = os.path.dirname(common)
        return os.path.join(main, "build", "catalog")
    except (OSError, subprocess.CalledProcessError):
        return os.path.join(REPO, "build", "catalog")


def lock_path():
    return os.environ.get("QCAT_LOCK") or os.path.join(data_dir(), "corpus.lock.jsonl")


def user_agent():
    """The descriptive User-Agent for Wikimedia and the Gutenberg feeds, from
    supabase/catalog/user_agent.txt (one line, with a contact the founder chose)."""
    path = os.path.join(data_dir(), USER_AGENT_FILE)
    with open(path, encoding="utf-8") as f:
        ua = f.read().strip()
    if not ua or "(" not in ua:
        raise SystemExit("user_agent.txt must hold a User-Agent with a contact, e.g. 'QuotedCatalog/0.1 (contact)'")
    return ua
