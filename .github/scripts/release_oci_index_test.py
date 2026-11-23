#!/usr/bin/env python3
"""release-oci.yaml 2.0.0: the index's preconditions are checked before anything is pushed.

1. The index preflight (the `# BEGIN index preflight` ... `# END index preflight` block, run as written):
     refused  an unknown channel; a channel but none with no token; a token with a trailing newline, a space
              inside it, or a tab; blueprints or pages with oci_repo outside oci://ghcr.io/krateo-blueprints/charts
              (its krateo-platformops default, an old org name)
     accepted none with no token; a channel with a clean token; operators with another registry
   and the token is never printed. Then the block is deleted and every refused case must be accepted.
2. Structure, read from the file:
     - index_channel is a required input; charts_publish_token is an optional secret;
     - package-and-push needs index-preflight;
     - the index gate call is guarded by the channel not being none, comes after the packaging loop and before
       the registry guard (and so before any push), and runs the index-gate action located in an earlier step;
     - the index-gate action, the nested release-preflight and publish-chart are pinned to one charts commit;
     - after the push: collect (only for a channel, outside a dry run, when the release has charts) pulls back
       the release's charts and publish-index indexes that artifact with the token;
3. The release charts output block, run as written: every chart published at its version is listed by its package's
   name and version, pushed or skipped as already published, so re-running a release that pushed but did not
   index finishes it.
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
BP = "oci://ghcr.io/krateo-blueprints/charts"
PO = "oci://ghcr.io/krateo-platformops/charts"
CASES = [
    # (label, channel, token, oci_repo, refused?)
    ("none, no token", "none", "", PO, False),
    ("blueprints, a clean token, the blueprints registry", "blueprints", TOKEN, BP, False),
    ("operators, a clean token, another registry", "operators", TOKEN, PO, False),
    ("an unknown channel", "blueprint", TOKEN, BP, True),
    ("blueprints, no token", "blueprints", "", BP, True),
    ("operators, a token with a trailing newline", "operators", TOKEN + "\n", PO, True),
    ("pages, a token with a space inside", "pages", TOKEN[:10] + " " + TOKEN[10:], BP, True),
    ("blueprints, a token with a tab", "blueprints", TOKEN + "\t", BP, True),
    ("blueprints with oci_repo left at krateo-platformops' default", "blueprints", TOKEN, PO, True),
    ("pages with oci_repo under the org's old name", "pages", TOKEN, "oci://ghcr.io/krateoplatformops/charts", True),
]


def run(script, channel, token, oci):
    env = {"PATH": os.environ["PATH"], "INDEX_CHANNEL": channel, "CHARTS_PUBLISH_TOKEN": token, "OCI_REPO": oci}
    p = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


script = block()
for label, channel, token, oci, refused in CASES:
    rc, out = run(script, channel, token, oci)
    ok = (rc != 0) if refused else (rc == 0)
    leaked = token.strip() and token.strip() in out
    print(f"{'ok  ' if ok and not leaked else 'FAIL'} {'refuses' if refused else 'accepts'}: {label}" + (" (TOKEN PRINTED)" if leaked else ""))
    if not ok or leaked:
        bad.append(label); print(textwrap.indent(out, "      "))
for label, channel, token, oci, refused in CASES:
    if refused:
        rc, out = run("true", channel, token, oci)
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
pins = re.findall(r"uses:\s*krateo-blueprints/charts/\.github/(?:workflows/release-preflight\.yaml|workflows/publish-chart\.yaml|actions/index-gate)@([0-9a-f]{40})", TEXT)
checks = [
    ("index_channel is a required input", wc["inputs"].get("index_channel", {}).get("required") is True),
    ("charts_publish_token is an optional secret", wc.get("secrets", {}).get("charts_publish_token", {}).get("required") is False),
    ("package-and-push needs index-preflight", "index-preflight" in needs),
    ("the index gate is located before the step that runs it", "Index gate" in names and names.index("Index gate") < names.index(next(n for n in names if n.startswith("Discover, version, package")))),
    ("the gate call comes after packaging and before the registry guard and the push", 0 <= pkg < call < loop_end < pushdef),
    ("the gate call is guarded by the channel not being none", '"${INDEX_CHANNEL:-none}" != none' in gate_block and "INDEX_GATE" in gate_block),
    ("release-preflight, index-gate and publish-chart are pinned to one charts commit", len(pins) == 3 and len(set(pins)) == 1),
    ("the preflight allows a pre-release exactly when index_channel is none",
     str(jobs.get("release-preflight", {}).get("with", {}).get("allow-prerelease", "")).replace(" ", "") == "${{inputs.index_channel=='none'}}"),
]
collect = jobs.get("collect", {})
publish = jobs.get("publish-index", {})
cif = str(collect.get("if", ""))
upload = [st for st in collect.get("steps", []) if str(st.get("uses", "")).startswith("actions/upload-artifact")]
checks += [
    ("package-and-push outputs the release's charts", "release_charts" in jobs["package-and-push"].get("outputs", {})),
    ("collect runs after package-and-push", "package-and-push" in (collect.get("needs") if isinstance(collect.get("needs"), list) else [collect.get("needs")])),
    ("collect runs only for a channel, outside a dry run, and when the release has charts",
     "inputs.index_channel != 'none'" in cif and "!inputs.dry_run" in cif and "outputs.release_charts != '[]'" in cif),
    ("publish-index runs after collect and calls charts' publish-chart",
     publish.get("needs") in (["collect"], "collect") and str(publish.get("uses", "")).startswith("krateo-blueprints/charts/.github/workflows/publish-chart.yaml@")),
    ("publish-index indexes collect's artifact, with the publish token",
     bool(upload) and upload[0].get("with", {}).get("name") == publish.get("with", {}).get("artifact")
     and "secrets.charts_publish_token" in str(publish.get("secrets", {}).get("PUBLISH_TOKEN", ""))),
]

# The release charts output block, run as written: every published chart in (pushed or skipped), names from the PACKAGE.
import io, tarfile, tempfile, json
m = re.search(r"\n[ \t]*# BEGIN release charts output.*?\n(.*?)\n[ \t]*# END release charts output", TEXT, re.S)
if not m:
    sys.exit("VOID: the release charts output block is not marked")
output_block = textwrap.dedent(m.group(1))
work = tempfile.mkdtemp()
def pkg(dirname, name, version):
    os.makedirs(os.path.join(work, dirname), exist_ok=True)
    open(os.path.join(work, dirname, "Chart.yaml"), "w").write(f"apiVersion: v2\nname: {name}\nversion: {version}\n")
    tgz = os.path.join(work, f"{name}-{version}.tgz")
    data = f"apiVersion: v2\nname: {name}\nversion: {version}\n".encode()
    with tarfile.open(tgz, "w:gz") as t:
        ti = tarfile.TarInfo(f"{name}/Chart.yaml"); ti.size = len(data); t.addfile(ti, io.BytesIO(data))
    return tgz
a = pkg("chart", "demo", "1.2.3"); b = pkg("config-chart", "demo-config", "1.2.3"); c = pkg("charts/old", "old", "0.7.0")
for label, skipped, want in (
    ("a pushed chart and a skipped (already published) one are both listed, by their package's name",
     "config-chart charts/old", [{"name": "demo", "version": "1.2.3"}, {"name": "demo-config", "version": "1.2.3"}, {"name": "old", "version": "0.7.0"}]),
    ("all skipped still lists every chart, so a re-run indexes a half-done release", "chart config-chart charts/old",
     [{"name": "demo", "version": "1.2.3"}, {"name": "demo-config", "version": "1.2.3"}, {"name": "old", "version": "0.7.0"}]),
):
    skip_decl = " ".join(f'skip_of["{d}"]=1;' for d in skipped.split())
    prog = (f'set -euo pipefail\ncd "{work}"\ncharts=(chart config-chart charts/old)\n'
            f'declare -A tgz_of=([chart]="{a}" [config-chart]="{b}" [charts/old]="{c}")\n'
            'declare -A ok_of=([chart]=1 [config-chart]=1 [charts/old]=1)\ndeclare -A skip_of=()\n'
            f'{skip_decl}\nGITHUB_OUTPUT="{work}/out"; : > "$GITHUB_OUTPUT"\n{output_block}\n')
    p = subprocess.run(["bash", "-c", prog], capture_output=True, text=True)
    out = open(os.path.join(work, "out")).read().strip() if os.path.exists(os.path.join(work, "out")) else ""
    got = json.loads(out.split("=", 1)[1]) if out.startswith("release_charts=") else None
    checks.append((label, p.returncode == 0 and got == want))
    if got != want:
        print(p.stdout + p.stderr, "got:", got)
for label, ok in checks:
    print(f"{'ok  ' if ok else 'FAIL'} {label}")
    if not ok:
        bad.append(label)
if bad:
    print(f"\n{len(bad)} expectation(s) failed"); sys.exit(1)
print(f"\nall {len(CASES)} preflight cases, the deletion and {len(checks)} structural checks hold")
