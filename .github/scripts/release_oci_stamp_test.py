#!/usr/bin/env python3
"""release-oci.yaml: no placeholder survives in a file it stamps, the preflight runs before any push, and
a dry run pushes nothing.

1. The stamp check (the `# BEGIN stamp check` ... `# END stamp check` block, run as written) against
   packages built here:
     refused  a placeholder left in appVersion, version, values.yaml, the CompositionDefinition, or a file
              nothing stamps (values.schema.json); SOURCE_REF left in Chart.yaml; an authored version or
              appVersion carrying another version; a package whose Chart.yaml is not at <name>/Chart.yaml
              (the check's own control: it must refuse rather than pass by failing to look)
     accepted a fully stamped package; one with no values.yaml; a placeholder only in a template (never
              stamped, never checked: portal's builder templates carry it on purpose); a literal version
              (PUBLISHING.md rule 4, a chart versioned on its own)
   Then the block is deleted and every refused case must be accepted: they are refused by this check.
2. Structure, read from the file:
     - package-and-push `needs:` release-preflight (structural order, not textual), which calls
       krateo-blueprints/charts release-preflight.yaml;
     - the dry-run exit and the stamp check both come before push_chart is defined;
     - Chart.yaml and values.yaml are stamped with an unanchored global substitution of CHART_VERSION;
     - the package upload runs in both modes.
"""
import io, os, re, subprocess, sys, tarfile, tempfile, textwrap

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
WF = os.path.join(ROOT, ".github", "workflows", "release-oci.yaml")
TEXT = open(WF).read()
bad = []


def block():
    m = re.search(r"\n([ \t]*)# BEGIN stamp check.*?\n(.*?)\n[ \t]*# END stamp check", TEXT, re.S)
    if not m:
        sys.exit("stamp check block not found")
    return textwrap.dedent(m.group(2))


def package(path, files, top="demo"):
    with tarfile.open(path, "w:gz") as t:
        for name, body in files.items():
            data = body.encode()
            ti = tarfile.TarInfo(f"{top}/{name}"); ti.size = len(data)
            t.addfile(ti, io.BytesIO(data))


CHART = "apiVersion: v2\nname: demo\nversion: {v}\nappVersion: {a}\n"
STAMPED = CHART.format(v="1.2.3", a="1.2.3")
# (label, files, refused?, message the refusal must carry, authored placeholders (version, appVersion), package top dir)
CASES = [
    ("a fully stamped package", {"Chart.yaml": STAMPED, "values.yaml": "image:\n  tag: \"1.2.3\"\n"}, False, "", (1, 1), "demo"),
    ("no values.yaml", {"Chart.yaml": STAMPED}, False, "", (1, 1), "demo"),
    ("a placeholder only in a template", {"Chart.yaml": STAMPED, "templates/_builder.tpl": "version: CHART_VERSION\n"}, False, "", (1, 1), "demo"),
    ("a literal version (PUBLISHING.md rule 4, versioned on its own)", {"Chart.yaml": CHART.format(v="0.7.0", a="2026.1")}, False, "", (0, 0), "demo"),
    ("CHART_VERSION left in appVersion", {"Chart.yaml": CHART.format(v="1.2.3", a="CHART_VERSION")}, True, "unstamped placeholder", (1, 1), "demo"),
    ("CHART_VERSION left in version", {"Chart.yaml": CHART.format(v="CHART_VERSION", a="1.2.3")}, True, "unstamped placeholder", (1, 1), "demo"),
    ("CHART_VERSION left in values.yaml", {"Chart.yaml": STAMPED, "values.yaml": "image:\n  tag: \"CHART_VERSION\"\n"}, True, "unstamped placeholder", (1, 1), "demo"),
    ("SOURCE_REF left in Chart.yaml", {"Chart.yaml": STAMPED + "annotations:\n  ref: SOURCE_REF\n"}, True, "unstamped placeholder", (1, 1), "demo"),
    ("CHART_VERSION left in compositiondefinition.yaml", {"Chart.yaml": STAMPED, "compositiondefinition.yaml": "spec:\n  chart:\n    version: CHART_VERSION\n"}, True, "unstamped placeholder", (1, 1), "demo"),
    ("CHART_VERSION in a file nothing stamps (values.schema.json)", {"Chart.yaml": STAMPED, "values.schema.json": "{\"default\": \"CHART_VERSION\"}\n"}, True, "unstamped placeholder", (1, 1), "demo"),
    ("an authored version carrying another version", {"Chart.yaml": CHART.format(v="0.1.9", a="1.2.3")}, True, "wrong version", (1, 1), "demo"),
    ("an authored appVersion carrying another version", {"Chart.yaml": CHART.format(v="1.2.3", a="1.0.0")}, True, "wrong version", (1, 1), "demo"),
    ("a package whose Chart.yaml is not at <name>/Chart.yaml", {"Chart.yaml": CHART.format(v="1.2.3", a="CHART_VERSION")}, True, "cannot read", (1, 1), "other"),
]


def run(script, files, placeholders, top):
    d = tempfile.mkdtemp()
    tgz = os.path.join(d, "demo-1.2.3.tgz")
    package(tgz, files, top)
    prog = ('set -euo pipefail\ndeclare -A tgz_of=(); d=chart; tgz_of[chart]="%s"; cname=demo; CHART_VERSION=1.2.3\n'
            'ver_placeholder=%d; app_placeholder=%d\n%s\necho PASSED\n') % (tgz, placeholders[0], placeholders[1], script)
    p = subprocess.run(["bash", "-c", prog], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


check = block()
for label, files, refused, msg, ph, top in CASES:
    rc, out = run(check, files, ph, top)
    ok = (rc != 0 and msg in out) if refused else (rc == 0 and "PASSED" in out)
    print(f"{'ok  ' if ok else 'FAIL'} {'refuses' if refused else 'accepts'}: {label}")
    if not ok:
        bad.append(label); print(textwrap.indent(out, "      "))
for label, files, refused, msg, ph, top in CASES:
    if not refused:
        continue
    rc, out = run("true", files, ph, top)
    ok = rc == 0
    print(f"{'ok  ' if ok else 'FAIL'} without the stamp check, '{label}' is accepted")
    if not ok:
        bad.append(f"deletion: {label}")

# Structure.
import yaml  # PyYAML, installed by the test workflow
wf = yaml.safe_load(TEXT)
jobs = wf["jobs"]
needs = jobs["package-and-push"].get("needs", [])
needs = [needs] if isinstance(needs, str) else needs
checks = [
    ("package-and-push needs release-preflight", "release-preflight" in needs),
    ("release-preflight calls krateo-blueprints/charts release-preflight.yaml",
     str(jobs.get("release-preflight", {}).get("uses", "")).startswith("krateo-blueprints/charts/.github/workflows/release-preflight.yaml@")),
]
script = next(st["run"] for st in jobs["package-and-push"]["steps"] if st.get("name", "").startswith("Discover, version, package"))
dry = script.find('if [ "${DRY_RUN:-false}" = "true" ]')
pushdef = script.find("push_chart() {")
checks.append(("the dry-run exit comes before push_chart is defined", 0 <= dry < pushdef))
checks.append(("the stamp check comes before push_chart is defined", 0 <= script.find("# BEGIN stamp check") < pushdef))
checks.append(("Chart.yaml is stamped with a global, unanchored substitution",
               re.search(r'sed -i "s/CHART_VERSION/\$\{CHART_VERSION\}/g; s/SOURCE_REF/\$\{CHART_VERSION\}/g" "\$\{d\}/Chart.yaml"', script) is not None))
checks.append(("values.yaml is stamped with a global, unanchored substitution",
               re.search(r'sed -i "s/CHART_VERSION/\$\{CHART_VERSION\}/g" "\$\{d\}/values.yaml"', script) is not None))
checks.append(("no substitution is anchored on a version key",
               re.search(r's/[A-Za-z_]*[Vv]ersion:\s*CHART_VERSION', script) is None))
upload = [st for st in jobs["package-and-push"]["steps"] if st.get("name") == "Upload the packages"]
checks.append(("the package upload runs in both modes", bool(upload) and "always()" in str(upload[0].get("if", ""))))
for label, ok in checks:
    print(f"{'ok  ' if ok else 'FAIL'} {label}")
    if not ok:
        bad.append(label)

if bad:
    print(f"\n{len(bad)} expectation(s) failed"); sys.exit(1)
print(f"\nall {len(CASES)} stamp cases, the deletion and {len(checks)} structural checks hold")
