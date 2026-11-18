#!/usr/bin/env python3
"""release-oci.yaml refuses a chart version that is not rule 13's core plus an optional pre-release, before any push.

    python3 .github/scripts/release_version_test.py [repo-root]

Runs release-oci.yaml's own "Resolve versions" step (read out of the workflow, so this tests the bytes callers run)
with CHART_VERSION_INPUT set to each case, APP_VERSION_INPUT set so no API call is made, and checks its verdict:
  accepted: 1.2.3, 0.0.0, 10.20.30, 0.15.0, and pre-releases 1.2.3-rc.1, 1.2.3-main.gabc1234, 0.3.74-dev.g0123abc,
            1.0.0-alpha, 1.2.3-0, 1.2.3-0a, 1.2.3-x-y, 1.2.3-rc.0, 1.2.3--
  refused:  0.015.0, 01.2.3, 1.02.3 (leading zeros), v1.2.3, 1.2.3+build.5, 1.2.3-rc.1+b, 1.2, 1.2.3.4, 1.2.3-,
            1.2.3-rc..1, an empty input falling back to a branch name (main), " 1.2.3", x.y.z, 1.2.3-01, 1.2.3-rc.01,
            1.2.3-00 (a numeric pre-release identifier with a leading zero), 1.2.3-rc.1.
Then three mutants, each of which some refused case must notice: the check deleted, the core loosened to
`[0-9]+\\.[0-9]+\\.[0-9]+` (github-provider-kog#111's form), and each pre-release identifier loosened to
`[0-9A-Za-z-]+` (which accepts 1.2.3-01; SemVer 2.0 section 9 forbids a leading zero in a numeric identifier). Last, CORE must be the three groups of krateo-blueprints/charts'
PLAIN_VERSION byte for byte (`^` + CORE + `$` == PLAIN_VERSION), read from charts' release-preflight.yaml and
publish-chart.yaml at the given charts ref (default main; CHARTS_REF overrides), so the two cannot drift.
Fails (exit 2) when the step, the marked block or charts' definition cannot be read.
"""
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

import yaml

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
WF = os.path.join(ROOT, ".github", "workflows", "release-oci.yaml")
STEP = "Resolve versions"
CHARTS_REF = os.environ.get("CHARTS_REF", "main")
OK = ["1.2.3", "0.0.0", "10.20.30", "0.15.0", "1.2.3-rc.1", "1.2.3-main.gabc1234", "0.3.74-dev.g0123abc", "1.0.0-alpha",
      "1.2.3-0", "1.2.3-0a", "1.2.3-x-y", "1.2.3-rc.0", "1.2.3--"]
BAD = ["0.015.0", "01.2.3", "1.02.3", "v1.2.3", "1.2.3+build.5", "1.2.3-rc.1+b", "1.2", "1.2.3.4", "1.2.3-",
       "1.2.3-rc..1", "", " 1.2.3", "x.y.z", "1.2.3-01", "1.2.3-rc.01", "1.2.3-00", "1.2.3-rc.1."]
# Only a leading-zero numeric pre-release identifier tells the third mutant apart; the test checks it is caught by one.
LEADING_ZERO_PRE = {"1.2.3-01", "1.2.3-rc.01", "1.2.3-00"}
CORE_LINE = re.compile(r"^(\s*)CORE='([^']*)'\s*$", re.M)
PRE_LINE = re.compile(r"^(\s*)PRE_ID='([^']*)'\s*$", re.M)
PLAIN = re.compile(r"^\s*PLAIN_VERSION='([^']*)'\s*$", re.M)


def measurement_failed(msg):
    print("FAILED MEASUREMENT: " + msg)
    sys.exit(2)


steps = [s for job in (yaml.safe_load(open(WF))["jobs"] or {}).values() for s in job.get("steps") or [] if s.get("name") == STEP]
if len(steps) != 1:
    measurement_failed("expected one %r step in %s, found %d" % (STEP, WF, len(steps)))
script = steps[0]["run"]


def run(text, version):
    with tempfile.TemporaryDirectory() as d:
        p, out = os.path.join(d, "s.sh"), os.path.join(d, "out")
        open(p, "w").write(text)
        env = dict(os.environ, CHART_VERSION_INPUT=version, APP_VERSION_INPUT="9.9.9", GITHUB_REF_NAME="main",
                   GITHUB_REPOSITORY="krateo-platformops/example", GH_TOKEN="", GITHUB_OUTPUT=out)
        r = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", p], env=env, capture_output=True, text=True)
        return r.returncode == 0, r.stdout + r.stderr


failures = []
for v in OK:
    ok, out = run(script, v)
    print("%s  accepts %-24r" % ("ok  " if ok else "FAIL", v))
    if not ok:
        failures.append("refuses %r: %s" % (v, out.strip()[-200:]))
for v in BAD:
    ok, out = run(script, v)
    good = not ok and "is not X.Y.Z" in out
    print("%s  refuses %-24r" % ("ok  " if good else "FAIL", v))
    if not good:
        failures.append("accepts %r" % v)

lines = script.split("\n")
b = [i for i, l in enumerate(lines) if "# BEGIN chart-version check" in l]
e = [i for i, l in enumerate(lines) if "# END chart-version check" in l]
cores = CORE_LINE.findall(script)
if len(b) != 1 or len(e) != 1 or len(cores) != 1 or len(PRE_LINE.findall(script)) != 1:
    measurement_failed("the chart-version block, its CORE or its PRE_ID is not marked exactly once")
mutants = [("check deleted", "\n".join(lines[:b[0]] + lines[e[0] + 1:])),
           ("core loosened (github-provider-kog#111)",
            CORE_LINE.sub(lambda m: m.group(1) + "CORE='[0-9]+\\.[0-9]+\\.[0-9]+'", script, count=1)),
           ("pre-release loosened to [0-9A-Za-z-]+",
            PRE_LINE.sub(lambda m: m.group(1) + "PRE_ID='[0-9A-Za-z-]+'", script, count=1))]
for label, text in mutants:
    caught = [v for v in BAD if run(text, v)[0]]
    print("%s  mutant %-42s %s" % ("ok  " if caught else "FAIL", label,
                                  "caught by " + ", ".join(repr(v) for v in caught) if caught else "NOT CAUGHT"))
    if not caught:
        failures.append("mutant %s not caught" % label)
    elif label.startswith("pre-release") and not set(caught) <= LEADING_ZERO_PRE:
        failures.append("mutant %s caught by %s, not only by leading-zero pre-releases" % (label, caught))

# One definition with charts' rule 13.
core = cores[0][1]
for f in ("release-preflight.yaml", "publish-chart.yaml"):
    url = "https://raw.githubusercontent.com/krateo-blueprints/charts/%s/.github/workflows/%s" % (CHARTS_REF, f)
    try:
        text = urllib.request.urlopen(url, timeout=30).read().decode()
    except OSError as err:
        measurement_failed("cannot read %s: %s" % (url, err))
    plain = PLAIN.findall(text)
    if len(plain) != 1:
        measurement_failed("%s at %s holds %d PLAIN_VERSION definitions, not 1" % (f, CHARTS_REF, len(plain)))
    same = plain[0] == "^" + core + "$"
    print("%s  CORE is charts' %s PLAIN_VERSION at %s, byte for byte" % ("ok  " if same else "FAIL", f, CHARTS_REF))
    if not same:
        failures.append("CORE %r is not charts' %s PLAIN_VERSION %r" % (core, f, plain[0]))

if failures:
    for x in failures:
        print("FAIL: " + x)
    sys.exit(1)
print("OK: %d accepted, %d refused, 3 mutants caught, CORE identical to charts' PLAIN_VERSION" % (len(OK), len(BAD)))
