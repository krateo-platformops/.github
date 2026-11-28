#!/usr/bin/env python3
"""chart-images.yaml: the cannot-render notice and the zero-document warning, run as written.

    python3 -I .github/scripts/chart_images_test.py [repo-root]     (needs helm, yq and bash on PATH)

The step "Verify chart-referenced images exist" is lifted out of the workflow and executed, unmodified, once per
fixture chart in .github/scripts/testdata/chart-images/ (chart_root = that one directory's parent copy, no
registry or network: the fixtures reference no image, so the image loop never runs). Nothing is re-implemented
here, so the test cannot drift from the workflow.

  required-refuses   ::error:: did not render, then the remedy ::notice:: (names ci/*-values.yaml and .helmignore);
                     the gate fails
  required-with-ci   the same chart with ci/render-values.yaml: renders, no error/notice/warning, and at least one
                     object (counted here with helm + yq, independently of the workflow); the gate passes
  zero-documents     renders nothing by default: the ::warning:: carries the ci/*-values.yaml advice AND the
                     .helmignore sentence; the gate still passes (advisory)
  one-object         renders exactly one object: no warning (the boundary is zero, not one); the gate passes

These fixtures are the only coverage the notice and the warning have: a healthy repository never reaches the
first. Each fixture directory says so.
"""
import os, re, shutil, subprocess, sys, tempfile
import yaml

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
WF = os.path.join(ROOT, ".github", "workflows", "chart-images.yaml")
FIX = os.path.join(ROOT, ".github", "scripts", "testdata", "chart-images")
STEP = "Verify chart-referenced images exist"
HELMIGNORE = "A .helmignore listing ci/ and .helmignore keeps those files out of the published package"
bad = []

steps = yaml.safe_load(open(WF))["jobs"]["chart-images"]["steps"]
run = [s["run"] for s in steps if s.get("name") == STEP]
if len(run) != 1:
    print(f"VOID: expected one step named {STEP!r} in chart-images.yaml, found {len(run)}")
    sys.exit(2)
tmp = tempfile.mkdtemp()
script = os.path.join(tmp, "step.sh")
open(script, "w").write(run[0])


def gate(name):
    """Run the workflow's step over one fixture; return (exit code, output)."""
    root = os.path.join(tmp, "root-" + name)
    shutil.copytree(os.path.join(FIX, name), os.path.join(root, name))
    env = dict(os.environ, CHART_VERSION_IN="1.2.3", APP_VERSION_IN="4.5.6", CHART_ROOT=root,
               GH_TOKEN="unused", GITHUB_REPOSITORY="example/example", GITHUB_REF="refs/heads/test")
    p = subprocess.run(["bash", script], env=env, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def objects(name):
    """Independent count: helm template of a stamped copy (the fixtures carry the real placeholders), then yq."""
    d = os.path.join(tmp, "count-" + name)
    shutil.copytree(os.path.join(FIX, name), d)
    cy = os.path.join(d, "Chart.yaml")
    t = open(cy).read().replace("CHART_VERSION", "1.2.3").replace("APP_VERSION", "4.5.6")
    open(cy, "w").write(t)
    vals = [a for f in sorted(os.listdir(os.path.join(d, "ci"))) if f.endswith("-values.yaml")
            for a in ("-f", os.path.join(d, "ci", f))] if os.path.isdir(os.path.join(d, "ci")) else []
    r = subprocess.run(["helm", "template", "x", d, *vals], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    y = subprocess.run(["yq", "eval-all", '[select(tag == "!!map" and has("kind"))] | length'],
                       input=r.stdout, capture_output=True, text=True)
    return int(y.stdout.strip().splitlines()[-1])


def expect(case, cond, out):
    if not cond:
        bad.append(case)
        print(f"FAIL {case}\n" + re.sub(r"(?m)^", "    ", out))
    else:
        print(f"ok   {case}")


def has(out, *needles):
    return all(n in out for n in needles)


rc, out = gate("required-refuses")
expect("required-refuses: gate fails", rc != 0, out)
expect("required-refuses: ::error:: names the chart and the required message",
       has(out, "::error::required-refuses did not render", "x is required"), out)
expect("required-refuses: remedy ::notice:: names ci/*-values.yaml and .helmignore",
       has(out, "::notice::required-refuses: a chart that needs values to render can ship",
           "ci/*-values.yaml", "A .helmignore listing ci/ and .helmignore keeps those files out of the published package."), out)
expect("required-refuses: no zero-document warning on a chart that did not render", "was not inspected" not in out, out)

rc, out = gate("required-with-ci")
n = objects("required-with-ci")
expect("required-with-ci: gate passes", rc == 0, out)
expect("required-with-ci: used the ci values file", "rendering with 1 ci values file(s)" in out, out)
expect("required-with-ci: no error, notice or warning",
       not any(m in out for m in ("::error::", "::notice::", "::warning::")), out)
expect("required-with-ci: renders at least one object (helm + yq)", n is not None and n >= 1, f"objects={n}\n{out}")

rc, out = gate("zero-documents")
n = objects("zero-documents")
expect("zero-documents: gate passes (advisory)", rc == 0, out)
expect("zero-documents: control, helm renders it with zero objects", n == 0, f"objects={n}")
expect("zero-documents: ::warning:: carries the ci values advice and the .helmignore sentence",
       has(out, "::warning::zero-documents was not inspected", "A ci/*-values.yaml in",
           HELMIGNORE + ", so adding them costs no chart version bump."), out)
expect("zero-documents: no ::error::", "::error::" not in out, out)

rc, out = gate("one-object")
n = objects("one-object")
expect("one-object: gate passes", rc == 0, out)
expect("one-object: control, helm renders exactly one object", n == 1, f"objects={n}")
expect("one-object: no warning, error or notice (boundary is zero, not one)",
       not any(m in out for m in ("::error::", "::notice::", "::warning::")), out)

shutil.rmtree(tmp)
if bad:
    print(f"\n{len(bad)} check(s) failed")
    sys.exit(1)
print("\nok  chart-images: cannot-render notice and zero-document warning fire as designed, and only there")
