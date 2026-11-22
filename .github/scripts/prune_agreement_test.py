#!/usr/bin/env python3
"""release-oci never publishes a chart the repository standard calls a fixture.

The standard (krateo-blueprints/charts .github/workflows/repository-standard.yaml) ignores Chart.yaml files under
the directories its FIXTURE pattern names. release-oci discovers charts with `find ... -prune`. If the standard
ignores a directory release-oci does not prune, a repository that passes the standard has that fixture chart
packaged and pushed on every release (found for e2e, sample and samples in 1.1.0).

Reads the krateo-blueprints/charts commit release-oci already pins (its nested release-preflight), fetches the
standard at that commit, and requires:
  - release-oci's prune set to contain every FIXTURE alternative (stricter than the standard is allowed);
  - chart-images.yaml's prune set to equal release-oci's (the image gate checks the charts release-oci publishes).
It fails as VOID, distinctly, when the pin, the file or a pattern cannot be found: a failed read is never agreement.
"""
import os, re, sys, urllib.request

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
WF = os.path.join(ROOT, ".github", "workflows")


def void(msg):
    print(f"VOID: {msg}"); sys.exit(2)


def prune_set(path):
    text = open(path).read()
    m = re.search(r"find \"\$\{CHART_ROOT:-\.\}\" -mindepth 1 \\\( (.*?) \\\) -prune", text)
    if not m:
        void(f"no find ... -prune discovery in {os.path.basename(path)}")
    return set(re.findall(r"-name (\S+)", m.group(1)))


release = open(os.path.join(WF, "release-oci.yaml")).read()
pins = re.findall(r"uses:\s*krateo-blueprints/charts/\.github/workflows/release-preflight\.yaml@([0-9a-f]{40})", release)
if len(pins) != 1:
    void(f"expected one pinned krateo-blueprints/charts release-preflight in release-oci.yaml, found {len(pins)}")
sha = pins[0]
url = f"https://raw.githubusercontent.com/krateo-blueprints/charts/{sha}/.github/workflows/repository-standard.yaml"
try:
    standard = urllib.request.urlopen(url, timeout=30).read().decode()
except Exception as e:
    void(f"cannot fetch the repository standard at {sha}: {e}")
m = re.search(r'FIXTURE = re\.compile\(r"\(\^\|/\)\(([^)]*)\)\(/\|\$\)"\)', standard)
if not m:
    void(f"no FIXTURE pattern in repository-standard.yaml at {sha}")
fixture = set()
for alt in m.group(1).split("|"):
    if alt.endswith("s?"):
        fixture |= {alt[:-2], alt[:-1]}
    else:
        fixture.add(alt)

ro = prune_set(os.path.join(WF, "release-oci.yaml"))
ci = prune_set(os.path.join(WF, "chart-images.yaml"))
bad = []
missing = sorted(fixture - ro)
print(f"standard FIXTURE at {sha[:12]}: {sorted(fixture)}")
print(f"release-oci prunes:            {sorted(ro)}")
if missing:
    bad.append(f"release-oci does not prune {missing}, which the standard treats as fixtures: their charts would be published")
if ci != ro:
    bad.append(f"chart-images.yaml prunes {sorted(ci)}, not release-oci's set (differs by {sorted(ci ^ ro)})")
for b in bad:
    print(f"FAIL {b}")
if bad:
    sys.exit(1)
print("ok  release-oci prunes every fixture directory of the standard, and chart-images prunes the same set")
