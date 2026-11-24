#!/usr/bin/env python3
"""The content gate release-oci runs before the push is the gate publish-chart runs at index time.

release-oci pins krateo-blueprints/charts' index-gate action, and calls publish-chart, which pins the same action
itself. Two pins of one definition, in two repositories: if publish-chart's moves to a gate.sh with another rule
and release-oci's does not, a chart can be pushed and then refused by the index, pullable and never listed. Nothing
else compares them; charts' own identity test sees publish-chart's pin only.

Reads release-oci's index-gate commit and its publish-chart commit, then, at that publish-chart commit, the
index-gate commit publish-chart pins, and requires the two gate.sh to be byte-identical. VOID, distinctly, when a
pin or a file cannot be read: a failed read is never agreement.

  python3 .github/scripts/gate_agreement_test.py [ROOT]
"""
import os, re, sys, urllib.request

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
RAW = "https://raw.githubusercontent.com/krateo-blueprints/charts/%s/%s"
GATE = ".github/actions/index-gate/gate.sh"
PUBLISH = ".github/workflows/publish-chart.yaml"


def void(msg):
    print("VOID: " + msg); sys.exit(2)


def one_pin(text, what, where):
    pins = re.findall(r"uses:\s*krateo-blueprints/charts/%s@([0-9a-f]{40})\b" % re.escape(what), text)
    if len(pins) != 1:
        void("expected one commit pin of %s in %s, found %d" % (what, where, len(pins)))
    return pins[0]


def fetch(sha, path):
    try:
        return urllib.request.urlopen(RAW % (sha, path), timeout=30).read()
    except Exception as e:
        void("cannot read %s at %s: %s" % (path, sha, e))


def compare(release, fetch=fetch):
    """(ok, message) for the text of release-oci.yaml."""
    mine = one_pin(release, ".github/actions/index-gate", "release-oci.yaml")
    pub = one_pin(release, PUBLISH, "release-oci.yaml")
    theirs = one_pin(fetch(pub, PUBLISH).decode(), ".github/actions/index-gate", "publish-chart.yaml at " + pub[:12])
    a, b = fetch(mine, GATE), fetch(theirs, GATE)
    if not a.strip() or not b.strip():
        void("an empty gate.sh was read")
    msg = "release-oci's gate %s, publish-chart@%s's gate %s" % (mine[:12], pub[:12], theirs[:12])
    return a == b, msg


def main():
    try:
        release = open(os.path.join(ROOT, ".github", "workflows", "release-oci.yaml")).read()
    except OSError as e:
        void(str(e))
    # The comparison itself is proven first, on canned files: equal passes, one byte apart fails.
    s = {c: c * 40 for c in "123"}
    text = ("uses: krateo-blueprints/charts/.github/actions/index-gate@%s\nuses: krateo-blueprints/charts/%s@%s\n"
            % (s["1"], PUBLISH, s["2"]))
    files = {(s["2"], PUBLISH): b"uses: krateo-blueprints/charts/.github/actions/index-gate@" + s["3"].encode(),
             (s["1"], GATE): b"same", (s["3"], GATE): b"same"}
    if not compare(text, lambda sha, path: files[(sha, path)])[0]:
        print("FAIL: two identical gates were reported as different"); sys.exit(1)
    files[(s["3"], GATE)] = b"samf"
    if compare(text, lambda sha, path: files[(sha, path)])[0]:
        print("FAIL: two different gates were reported as identical"); sys.exit(1)
    ok, msg = compare(release)
    if not ok:
        print("FAIL: %s: their gate.sh differ. Move both pins to charts commits that carry the same gate.sh, "
              "or a chart can be pushed and then refused by the index." % msg); sys.exit(1)
    print("ok  %s: byte-identical" % msg)


if __name__ == "__main__":
    main()
