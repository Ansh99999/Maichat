#!/usr/bin/env python3
"""Mask credential-shaped strings in a staging tree before it leaves the machine.

Runs over the *staging copy* only -- never the live ~/.claude files. Claude Code
transcripts embed the contents of every file read during a session, so an API key
in settings.json ends up verbatim inside projects/*.jsonl. Upload without this
pass and the key lands in Google Drive.

  drive-redact.py scrub <dir>   rewrite files in place, report what was masked
  drive-redact.py check <dir>   exit 1 if anything still looks like a credential
"""
import re
import sys
import pathlib

# (compiled pattern, replacement, human label)
PATTERNS = [
    (re.compile(r"sk-ant-[A-Za-z0-9_\-]{16,}"), "sk-ant-REDACTED", "anthropic key"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "sk-REDACTED", "sk- key"),
    (re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}"), "gh_REDACTED", "github token"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "github_pat_REDACTED", "github pat"),
    (re.compile(r"AIza[A-Za-z0-9_\-]{30,}"), "AIza-REDACTED", "google api key"),
    (re.compile(r"ya29\.[A-Za-z0-9_\-]{20,}"), "ya29-REDACTED", "google oauth"),
    (re.compile(r"xox[baprs]-[A-Za-z0-9\-]{10,}"), "xox-REDACTED", "slack token"),
    (re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._\-]{20,}"), r"\1REDACTED", "bearer"),
    (re.compile(r"(?i)(\"?(?:access|refresh|id)_token\"?\s*[:=]\s*\"?)(?!REDACTED)[A-Za-z0-9._\-/+]{20,}"),
     r"\1REDACTED", "oauth token"),
    (re.compile(r"(?i)(ANTHROPIC_API_KEY\"?\s*[:=]\s*\"?)(?!REDACTED)[^\"\s,}]{8,}"), r"\1REDACTED", "env key"),
    (re.compile(r"(?i)(AWS_SECRET_ACCESS_KEY\"?\s*[:=]\s*\"?)(?!REDACTED)[^\"\s,}]{8,}"),
     r"\1REDACTED", "aws secret"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AKIA-REDACTED", "aws key id"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S),
     "-----REDACTED PRIVATE KEY-----", "private key"),
]

SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".pdf", ".zip", ".gz", ".so", ".bin"}


def iter_files(root: pathlib.Path):
    for p in sorted(root.rglob("*")):
        if p.is_file() and not p.is_symlink() and p.suffix.lower() not in SKIP_SUFFIXES:
            yield p


def read_text(path: pathlib.Path):
    try:
        return path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return None  # binary or unreadable -- leave it alone


def scrub(root: pathlib.Path) -> int:
    hits = {}
    changed = 0
    for path in iter_files(root):
        text = read_text(path)
        if text is None:
            continue
        original = text
        for pattern, replacement, label in PATTERNS:
            text, n = pattern.subn(replacement, text)
            if n:
                hits[label] = hits.get(label, 0) + n
        if text != original:
            path.write_text(text, encoding="utf-8")
            changed += 1
    if hits:
        detail = ", ".join(f"{label} x{n}" for label, n in sorted(hits.items()))
        print(f"redacted {sum(hits.values())} secret(s) in {changed} file(s): {detail}")
    else:
        print("redacted 0 secrets (nothing matched)")
    return 0


def check(root: pathlib.Path) -> int:
    bad = []
    for path in iter_files(root):
        text = read_text(path)
        if text is None:
            continue
        for pattern, _replacement, label in PATTERNS:
            if pattern.search(text):
                bad.append(f"{path.relative_to(root)}: {label}")
    if bad:
        print("FAIL -- credential-shaped strings still present:", file=sys.stderr)
        for line in bad[:20]:
            print(f"  {line}", file=sys.stderr)
        if len(bad) > 20:
            print(f"  ... and {len(bad) - 20} more", file=sys.stderr)
        return 1
    print("check clean -- no credential-shaped strings found")
    return 0


def main() -> int:
    if len(sys.argv) != 3 or sys.argv[1] not in {"scrub", "check"}:
        print(__doc__, file=sys.stderr)
        return 2
    mode, target = sys.argv[1], pathlib.Path(sys.argv[2]).resolve()
    if not target.is_dir():
        print(f"not a directory: {target}", file=sys.stderr)
        return 2
    # Hard guard: only ever touch a staging tree, never the live state.
    if mode == "scrub" and ".drive-stage" not in target.parts:
        print(f"refusing to scrub outside a .drive-stage tree: {target}", file=sys.stderr)
        return 2
    return scrub(target) if mode == "scrub" else check(target)


if __name__ == "__main__":
    sys.exit(main())
