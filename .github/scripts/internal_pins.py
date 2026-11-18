#!/usr/bin/env python3
"""Every call from this repository into itself is pinned by commit, so pinning a caller freezes all it runs.

    python3 .github/scripts/internal_pins.py [repo-root]   # self-test, then the scan

A caller that pins release-oci.yaml by SHA froze only release-oci.yaml's own text: the reusable then called
chart-images.yaml, chart-version-guard and chart-push at `@main`, so a push to this repository's main still changed
what every pinned caller ran (found independently by the github-provider-kog and azuredevops-provider-kog sessions,
2026-11-18). So every `uses:` of krateo-platformops/.github in a workflow or action file here must be:
  - a 40-hex commit, not a branch, tag or abbreviated SHA;
  - commented `# main YYYY-MM-DD`, the UTC committer date of that commit (the transitional form until this
    repository tags, krateo-blueprints/charts#23), or `# X.Y.Z`;
  - a commit on this checkout's history (`git merge-base --is-ancestor`), so a pin never names a branch commit that
    a squash merge leaves unreachable.
Local `./...` uses move with the commit and pass. Other owners' actions are out of scope here (charts rule 9 covers
reusable workflows only, decided in krateo-blueprints/charts#20).

A pinned commit must contain what it pins, so a change to a leaf (an action, a called workflow) needs two merges: the
leaf, then a bump of the pins that call it, leaves first. The bump is the reviewed moment the change reaches callers.

Fails when it scanned no file (a check that read nothing has checked nothing), and when its self-test misjudges a
planted line.
"""
import datetime
import glob
import os
import re
import subprocess
import sys

OWNER_REPO = "krateo-platformops/.github"
USES = re.compile(r"""^\s*(?:-\s+)?uses:\s*(['"]?)([^'"\s#]+)\1\s*(?:#\s*(.*?))?\s*$""")
SHA = re.compile(r"^[0-9a-f]{40}$")
DATED = re.compile(r"^main (\d{4}-\d{2}-\d{2})$")
VERSION = re.compile(r"^\d+\.\d+\.\d+$")


def problems(lines, ancestor, commit_date):
    """(line number, message) for every internal `uses:` that is not pinned as above."""
    out = []
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        m = USES.match(line)
        if not m:
            continue
        target, comment = m.group(2), (m.group(3) or "").strip()
        if not target.lower().startswith(OWNER_REPO + "/"):
            continue
        ref = target.rpartition("@")[2] if "@" in target else ""
        if not SHA.match(ref):
            out.append((n, "%s is at %r, not a 40-hex commit: pin internal calls by commit" % (target, ref)))
            continue
        dated, version = DATED.match(comment), VERSION.match(comment)
        if not (dated or version):
            out.append((n, "%s has comment %r; it needs `# main YYYY-MM-DD` (the pinned commit's date) or `# X.Y.Z`" % (target, comment)))
            continue
        if not ancestor(ref):
            out.append((n, "%s pins %s, which is not on this checkout's history (a branch commit a squash merge drops?)" % (target, ref)))
            continue
        if dated and commit_date(ref) != dated.group(1):
            out.append((n, "%s says `# main %s` but %s was committed on %s (UTC)" % (target, dated.group(1), ref[:12], commit_date(ref))))
    return out


def git_ancestor(root):
    def f(sha):
        return subprocess.run(["git", "-C", root, "merge-base", "--is-ancestor", sha, "HEAD"],
                              capture_output=True).returncode == 0
    return f


def git_date(root):
    def f(sha):
        r = subprocess.run(["git", "-C", root, "show", "-s", "--format=%ct", sha], capture_output=True, text=True)
        if r.returncode:
            return "unknown"
        return datetime.datetime.fromtimestamp(int(r.stdout.strip()), datetime.timezone.utc).strftime("%Y-%m-%d")
    return f


def self_test():
    good = "a" * 40
    ancestor = lambda sha: sha == good  # noqa: E731
    date = lambda sha: "2026-11-18"  # noqa: E731
    T = "krateo-platformops/.github/.github/actions/chart-push"
    refused = [
        "        uses: %s@main" % T,
        "    uses: krateo-platformops/.github/.github/workflows/chart-images.yaml@main",
        "      - uses: %s@v1 # 1.0.0" % T,
        "        uses: %s@fb91b76 # main 2026-11-18" % T,
        "        uses: %s@%s" % (T, good),
        "        uses: %s@%s # latest" % (T, good),
        "        uses: %s@%s # main 2026-11-17" % (T, good),
        "        uses: %s@%s # main 2026-11-18" % (T, "b" * 40),
        "        uses: Krateo-Platformops/.GitHub/.github/actions/chart-push@main",
        '        uses: "%s@main"' % T,
    ]
    accepted = [
        "        uses: %s@%s # main 2026-11-18" % (T, good),
        "        uses: %s@%s # 1.0.0" % (T, good),
        "        # uses: %s@main  (a comment)" % T,
        "        uses: ./.github/actions/chart-push",
        "      - uses: actions/checkout@v4",
        "        uses: krateo-blueprints/charts/.github/workflows/pinned-uses.yaml@main",
    ]
    bad = [l for l in refused if not problems([l], ancestor, date)] + [l for l in accepted if problems([l], ancestor, date)]
    for b in bad:
        print("FAIL: self-test misjudged: %s" % b.strip())
    if not bad:
        print("OK: self-test, %d planted unpinned internal uses refused, %d accepted forms passed" % (len(refused), len(accepted)))
    return 1 if bad else 0


def main(root):
    files = sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.y*ml"))
                   + glob.glob(os.path.join(root, ".github", "actions", "*", "action.y*ml")))
    if not files:
        print("FAILED MEASUREMENT: no workflow or action file under %s, so nothing was checked" % root)
        return 2
    ancestor, date = git_ancestor(root), git_date(root)
    failures, internal = [], 0
    for f in files:
        lines = open(f, encoding="utf-8").read().split("\n")
        internal += sum(1 for l in lines if not l.lstrip().startswith("#") and USES.match(l)
                        and USES.match(l).group(2).lower().startswith(OWNER_REPO + "/"))
        for n, msg in problems(lines, ancestor, date):
            failures.append("%s:%d: %s" % (os.path.relpath(f, root), n, msg))
    for x in failures:
        print("::error::" + x)
    print("%d file(s), %d internal uses, %d not pinned" % (len(files), internal, len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(self_test() or main(os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")))
