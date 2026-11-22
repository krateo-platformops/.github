#!/usr/bin/env python3
"""release-oci.yaml 2.0.0: the index's preconditions are checked before anything is pushed.

1. The index preflight (the `# BEGIN index preflight` ... `# END index preflight` block, run as written):
     refused  an unknown channel; a channel but none with no token; a token with a trailing newline, a space
              inside it, or a tab
     accepted none with no token; a channel with a clean token
   and the token is never printed. Then the block is deleted and every refused case must be accepted.
2. Structure, read from the file:
     - index_channel is a required input; charts_publish_token is an optional secret;
     - package-and-push needs index-preflight;
     - the index gate call is guarded by the channel not being none, comes after the packaging loop and before
       the registry guard (and so before any push), and runs the index-gate action located in an earlier step;
     - the index-gate action and the nested release-preflight are pinned to the same krateo-blueprints/charts
       commit.
"""
import os, re, subprocess, sys, textwrap
import yaml

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
TEXT = open(os.path.join(ROOT, ".github", "workflows", "release-oci.yaml")).read()
bad = []


def block():
    m = re.search(r"\n[ \t]*# BEGIN index preflight.*?\n(.*?)\n[ \t]*# END index preflight", TEXT, re.S)
    if not m:
        sys.exit("VOID: the index preflight block is not marked")
    return textwrap.dedent(m.group(1))


TOKEN = "ghp_" + "A1b2C3d4" * 4  # a token-shaped test value built at run time; not a credential
CASES = [
    # (label, channel, token, refused?)
    ("none, no token", "none", "", False),
    ("blueprints, a clean token", "blueprints", TOKEN, False),
    ("an unknown channel", "blueprint", TOKEN, True),
    ("blueprints, no token", "blueprints", "", True),
    ("operators, a token with a trailing newline", "operators", TOKEN + "\n", True),
    ("pages, a token with a space inside", "pages", TOKEN[:10] + " " + TOKEN[10:], True),
    ("blueprints, a token with a tab", "blueprints", TOKEN + "\t", True),
]


def run(script, channel, token):
    env = {"PATH": os.environ["PATH"], "INDEX_CHANNEL": channel, "CHARTS_PUBLISH_TOKEN": token}
    p = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


script = block()
for label, channel, token, refused in CASES:
    rc, out = run(script, channel, token)
    ok = (rc != 0) if refused else (rc == 0)
    leaked = token.strip() and token.strip() in out
    print(f"{'ok  ' if ok and not leaked else 'FAIL'} {'refuses' if refused else 'accepts'}: {label}" + (" (TOKEN PRINTED)" if leaked else ""))
    if not ok or leaked:
        bad.append(label); print(textwrap.indent(out, "      "))
for label, channel, token, refused in CASES:
    if refused:
        rc, out = run("true", channel, token)
        ok = rc == 0
        print(f"{'ok  ' if ok else 'FAIL'} without the preflight, '{label}' is accepted")
        if not ok:
            bad.append(f"deletion: {label}")

wf = yaml.safe_load(TEXT)
on = wf.get(True) or wf.get("on")
wc = on["workflow_call"]
jobs = wf["jobs"]
needs = jobs["package-and-push"].get("needs", [])
steps = jobs["package-and-push"]["steps"]
names = [s.get("name", "") for s in steps]
script_step = next(s["run"] for s in steps if s.get("name", "").startswith("Discover, version, package"))
call = script_step.find("# BEGIN index gate call")
loop_end = script_step.find("Ask the registry about every package before pushing any")
pkg = script_step.find("helm package")
pushdef = script_step.find("push_chart() {")
gate_block = script_step[call:script_step.find("# END index gate call")] if call >= 0 else ""
pins = re.findall(r"uses:\s*krateo-blueprints/charts/\.github/(?:workflows/release-preflight\.yaml|actions/index-gate)@([0-9a-f]{40})", TEXT)
checks = [
    ("index_channel is a required input", wc["inputs"].get("index_channel", {}).get("required") is True),
    ("charts_publish_token is an optional secret", wc.get("secrets", {}).get("charts_publish_token", {}).get("required") is False),
    ("package-and-push needs index-preflight", "index-preflight" in needs),
    ("the index gate is located before the step that runs it", "Index gate" in names and names.index("Index gate") < names.index(next(n for n in names if n.startswith("Discover, version, package")))),
    ("the gate call comes after packaging and before the registry guard and the push", 0 <= pkg < call < loop_end < pushdef),
    ("the gate call is guarded by the channel not being none", '"${INDEX_CHANNEL:-none}" != none' in gate_block and "INDEX_GATE" in gate_block),
    ("release-preflight and index-gate are pinned to one charts commit", len(pins) == 2 and len(set(pins)) == 1),
]
for label, ok in checks:
    print(f"{'ok  ' if ok else 'FAIL'} {label}")
    if not ok:
        bad.append(label)
if bad:
    print(f"\n{len(bad)} expectation(s) failed"); sys.exit(1)
print(f"\nall {len(CASES)} preflight cases, the deletion and {len(checks)} structural checks hold")
