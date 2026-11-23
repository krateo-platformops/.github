#!/usr/bin/env python3
"""The chart-push every workflow here pins passes TODAY's push rules, by contents, not by ancestry.

Every workflow pins .github/actions/chart-push by commit. push_test.py (beside the action) runs on the working
tree's push.sh, so a pin moved to another commit (backwards, or to a branch) is never tested by it. Commit 5f126b7
put the registry credential on curl's command line (`-u user:pass`, `-H "Authorization: Bearer ..."`), readable by
every process in the job through /proc/<pid>/cmdline; a pin moved back there passed every other check.

For each distinct pinned commit: the action directory at that commit (push.sh, action.yml) is extracted, today's
push_test.py is put beside it, and it runs there. So the pinned push.sh and push step must pass every current case
and catch every current mutant, the credential-off-argv cases included.

  python3 .github/scripts/pinned_chart_push_test.py [ROOT]          every pin found under ROOT/.github/workflows
  python3 .github/scripts/pinned_chart_push_test.py ROOT --sha SHA  one commit (the negative control: 5f126b7 fails)

Needs the pinned commits in the local clone (CI checks out with fetch-depth: 0). It fails as VOID, distinctly, when
no pin is found or a commit cannot be read: a failed read is never a pass.
"""
import glob, os, re, shutil, subprocess, sys, tempfile

args = [a for a in sys.argv[1:]]
only = None
if "--sha" in args:
    i = args.index("--sha"); only = args[i + 1]; del args[i:i + 2]
ROOT = os.path.abspath(args[0] if args else ".")
ACTION = ".github/actions/chart-push"
TEST = os.path.join(ROOT, ACTION, "push_test.py")
PIN = re.compile(r"uses:\s*krateo-platformops/\.github/\.github/actions/chart-push@([0-9a-f]{40})\b")


def void(msg):
    print("VOID: " + msg); sys.exit(2)


if only:
    pins = {only: ["--sha"]}
else:
    pins = {}
    for wf in sorted(glob.glob(os.path.join(ROOT, ".github", "workflows", "*.y*ml"))):
        for sha in PIN.findall(open(wf).read()):
            pins.setdefault(sha, []).append(os.path.basename(wf))
    if not pins:
        void("no workflow under .github/workflows pins krateo-platformops/.github/.github/actions/chart-push by commit")
if not os.path.isfile(TEST):
    void("%s is missing" % TEST)

bad = []
for sha, where in pins.items():
    tmp = tempfile.mkdtemp()
    try:
        arch = subprocess.run(["git", "-C", ROOT, "archive", "--format=tar", sha, ACTION], capture_output=True)
        if arch.returncode != 0:
            void("cannot read %s at %s (%s); fetch full history" % (ACTION, sha, arch.stderr.decode().strip()))
        subprocess.run(["tar", "-x", "-C", tmp], input=arch.stdout, check=True)
        d = os.path.join(tmp, ACTION)
        for f in ("push.sh", "action.yml"):
            if not os.path.isfile(os.path.join(d, f)):
                void("%s/%s does not exist at %s" % (ACTION, f, sha))
        shutil.copy(TEST, os.path.join(d, "push_test.py"))
        # stdin is /dev/null: an older step that reads a credential nobody pipes (a stand-in `helm registry login`
        # recording its stdin) must reach EOF and fail, not wait on an inherited terminal. The bound makes a hang VOID.
        try:
            p = subprocess.run([sys.executable, os.path.join(d, "push_test.py")], capture_output=True, text=True,
                               cwd=tmp, stdin=subprocess.DEVNULL, timeout=900)
        except subprocess.TimeoutExpired:
            void("push_test.py did not finish in 900 s against chart-push@%s" % sha)
        out = (p.stdout + p.stderr).strip().splitlines()
        ok = p.returncode == 0
        print("%s chart-push@%s (pinned by %s): %s" % ("ok  " if ok else "FAIL", sha[:12], ", ".join(where),
                                                        out[-1] if out else "no output"))
        if not ok:
            bad.append(sha)
            for line in out:
                if line.startswith("FAIL"):
                    print("      " + line)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
if bad:
    print("\n%d pinned chart-push commit(s) fail today's push rules: move the pin to a commit that passes them" % len(bad))
    sys.exit(1)
print("\nevery pinned chart-push (%d commit(s)) passes today's push rules" % len(pins))
