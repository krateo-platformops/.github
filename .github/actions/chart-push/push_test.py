#!/usr/bin/env python3
"""chart-push's push.sh retries ghcr.io's tag read-after-write race and nothing else; push mode outputs the digest.

    python3 .github/actions/chart-push/push_test.py                  # every case and mutant below (needs pyyaml)
    python3 .github/actions/chart-push/push_test.py --stage DIR CASE # write CASE's stand-ins into DIR, print the digest

Part 1, the script. push.sh runs against a stand-in `helm` (each `helm push` follows a plan: succeed with a digest, fail
with the race on a digest, or fail with another error) and a stand-in `curl` (a registry with a Bearer token challenge
whose manifest GET 404s until a chosen poll, and requires the token it issued). These are the 7 cases and 6 mutants of
krateo-blueprints/rabbitmq-operator-blueprint hack/validate-push-chart.py at e22d03a02714e892791710dfad4beb3c9be6fc80
(sha256 7aa121f7a63202924a4ec504de0eb8a0f6e6a56eb41fc895e557707a6b6da874), unchanged:

  ok         the first push succeeds                    -> 0, one push, no poll
  race       the race, the digest served on poll 2      -> 0, two pushes, the second on the same digest
  other      the tag step denied on that digest          -> 1, one push, no poll (a near miss of the race string)
  push500    the manifest PUT "not found" on that digest -> 1, one push, no poll (another near miss)
  never      the race, the digest never served          -> 1, one push, "still not served", every poll spent
  moved      the race, the second push on another digest -> 1
  wrongbody  the race, the registry serves other bytes  -> 1 (a body is not the digest until it hashes to it)

Mutants of the script (retry keyed on any error, the ': not found' suffix dropped, the Tag operation dropped, no poll,
no digest comparison, no body hash): each must make at least one case fail.

Then the cases for what push.sh changes from its source (marked "ADAPTED" there), each with a mutant where one applies:
  creds  the race with REGISTRY_USERNAME/REGISTRY_PASSWORD set -> the token request carries them (mutant: the source's
         REGISTRY_USER/REGISTRY_TOKEN names)
  big    an archive with 20000 entries -> 0, its name read from the first entry (no mutant: whether `| head -n1` kills
         tar depends on timing, so test-chart-push.yaml reports that, it does not gate on it)
  notgz  a file that is not a gzip archive -> 1, "not a readable chart archive" (mutant: no message)

Part 2, the action. The push step's shell is read out of action.yml, so this tests the bytes callers run, with the env
the step maps from its inputs (checked against action.yml first). Cases: locate mode (no inputs) does nothing and
passes; credentials without a chart fail; a push outputs the digest, and logs in once with the token on stdin, never in
argv or the log; the race outputs the same digest; another error outputs nothing; a push that reports no digest fails;
an empty password or user fails before helm runs; a repository that is not oci://... fails before helm runs. Then it
deletes or replaces each marked block (mode-check, input-check, digest-check, login) and requires the cases that block
exists for to fail.

The source validator's last check, that every workflow's `helm push` goes through the script, is krateo-blueprints/charts
PUBLISHING.md rule 14's job: its pinned-uses.yaml refuses a bare `helm push` or `oras push` in a caller's workflows.

Fails (exit 2) when bash, tar or a file it tests is missing: a check that could not run has checked nothing.
"""
import hashlib
import io
import os
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

ACTION_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(ACTION_DIR, "push.sh")
ACTION = os.path.join(ACTION_DIR, "action.yml")


def measurement_failed(msg):
    print("FAILED MEASUREMENT: " + msg)
    sys.exit(2)


BODY = b'{"schemaVersion":2,"stand-in":"manifest"}'
DIGEST = "sha256:" + hashlib.sha256(BODY).hexdigest()
OTHER = "sha256:" + "0" * 64
RACE = 'Error: failed to perform "Tag" on destination: %s: not found'
TOKEN = "stand-in-registry-token-5f2c"
USER = "stand-in-user"
REPO = "oci://reg.stand.in/org/charts"

# The source's stand-in helm, plus two additions for the action's step: `helm registry login` records its argv and its
# stdin (the token must arrive there, never in argv), and a `nodigest` plan line succeeds without a Digest line.
HELM = r'''#!/usr/bin/env bash
# stand-in helm: `helm push` follows $STUB/plan, one line per call; `helm registry login` records argv and stdin
if [ "${1:-} ${2:-}" = "registry login" ]; then
  shift 2; printf '%s\n' "$*" > "$STUB/login.args"; cat > "$STUB/login.stdin"
  n=$(( $(cat "$STUB/login.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/login.calls"
  echo "Login Succeeded"; exit 0
fi
[ "$1" = push ] || { echo "stand-in helm: unexpected $*" >&2; exit 99; }
n=$(( $(cat "$STUB/helm.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/helm.calls"
line="$(sed -n "${n}p" "$STUB/plan")"
case "$line" in
  ok\ *) echo "Pushed: x"; echo "Digest: ${line#ok }" ;;
  nodigest) echo "Pushed: x" ;;
  race\ *) echo "Error: failed to perform \"Tag\" on destination: ${line#race }: not found" >&2; exit 1 ;;
  err\ *) echo "Error: ${line#err }" >&2; exit 1 ;;
  *) echo "stand-in helm: no plan for call $n" >&2; exit 98 ;;
esac
'''

CURL = r'''#!/usr/bin/env bash
# stand-in curl: a registry with a Bearer challenge; the manifest is served from poll $STUB/at on
out="" headers=0 url="" auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    -D) headers=1; shift ;;
    -H) case "$2" in "Authorization: Bearer "*) auth="${2#Authorization: Bearer }" ;; esac; shift ;;
    -u) printf '%s\n' "$2" > "$STUB/curl.cred"; shift ;;
    --data-urlencode) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
case "$url" in
  https://auth.stand.in/token*) echo '{"token":"issued-token"}'; exit 0 ;;
  https://reg.stand.in/v2/*/manifests/*) ;;
  *) echo "stand-in curl: unexpected url $url" >&2; exit 99 ;;
esac
if [ "$headers" = 1 ]; then
  printf 'HTTP/2 401\r\nwww-authenticate: Bearer realm="https://auth.stand.in/token",service="reg.stand.in",scope="repository:org/charts/demo:pull"\r\n\r\n'
  exit 0
fi
[ "$auth" = issued-token ] || exit 22
n=$(( $(cat "$STUB/get.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB/get.calls"
[ "$n" -ge "$(cat "$STUB/at")" ] || exit 22
cat "$STUB/body" > "$out"
'''

# case: (helm plan, the poll the manifest is first served on, the bytes served)
CASES = {
    "ok": (["ok " + DIGEST], 1, BODY),
    "race": (["race " + DIGEST, "ok " + DIGEST], 2, BODY),
    # Near misses, on the same digest, with the digest servable at once: a script keyed on less than the whole race
    # string retries them and succeeds.
    "other": (["err " + (RACE % DIGEST)[len("Error: "):].replace(": not found", ": denied"), "ok " + DIGEST], 1, BODY),
    "push500": (["err failed to perform \"Push\" on destination: %s: not found" % DIGEST, "ok " + DIGEST], 1, BODY),
    "never": (["race " + DIGEST, "ok " + DIGEST], 999, BODY),
    "moved": (["race " + DIGEST, "ok " + OTHER], 1, BODY),
    "wrongbody": (["race " + DIGEST, "ok " + DIGEST], 1, b"other bytes"),
}
STAGE_ONLY = {
    "nodigest": (["nodigest"], 1, BODY),
    "creds": (["race " + DIGEST, "ok " + DIGEST], 2, BODY),
    "big": (["ok " + DIGEST], 1, BODY),
    "notgz": (["ok " + DIGEST], 1, BODY),
}
BIG_ENTRIES = 20000


def stage(stub, case):
    """Write CASE's stand-in helm and curl, its plan and a chart archive into stub; return the archive's path."""
    plan, at, body = {**CASES, **STAGE_ONLY}[case]
    bindir = os.path.join(stub, "bin")
    os.makedirs(bindir, exist_ok=True)
    for name, src in (("helm", HELM), ("curl", CURL)):
        p = os.path.join(bindir, name)
        open(p, "w").write(src)
        os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    open(os.path.join(stub, "plan"), "w").write("\n".join(plan) + "\n")
    open(os.path.join(stub, "at"), "w").write(str(at))
    open(os.path.join(stub, "body"), "wb").write(body)
    tgz = os.path.join(stub, "demo-0.1.0.tgz")
    if case == "notgz":
        open(tgz, "w").write("not a gzip archive\n")
        return tgz
    with tarfile.open(tgz, "w:gz") as t:
        data = b"name: demo\nversion: 0.1.0\n"
        info = tarfile.TarInfo("demo/Chart.yaml")
        info.size = len(data)
        t.addfile(info, io.BytesIO(data))
        # A listing far larger than one pipe write, as a chart that vendors helm-toolkit has.
        for k in range(BIG_ENTRIES if case == "big" else 0):
            info = tarfile.TarInfo("demo/templates/generated-file-with-a-long-name-%05d.yaml" % k)
            info.size = 0
            t.addfile(info, io.BytesIO(b""))
    return tgz


def count(stub, f):
    p = os.path.join(stub, f)
    return int(open(p).read()) if os.path.exists(p) else 0


def stub_env(stub):
    env = dict(os.environ, STUB=stub, PATH=os.path.join(stub, "bin") + os.pathsep + os.environ["PATH"],
               PUSH_POLL_ATTEMPTS="4", PUSH_POLL_INTERVAL="0")
    for k in ("REGISTRY_PASSWORD", "REGISTRY_USERNAME", "REGISTRY_TOKEN", "REGISTRY_USER", "CHART", "REPOSITORY",
              "GITHUB_OUTPUT", "GITHUB_ACTION_PATH"):
        env.pop(k, None)
    return env


# ---- part 1: the script -------------------------------------------------------------------------------------------

def run_case(script, case, tmp, env_extra=None):
    stub = tempfile.mkdtemp(dir=tmp)
    tgz = stage(stub, case)
    env = stub_env(stub)
    env.update(env_extra or {})
    r = subprocess.run(["bash", script, tgz, REPO], env=env, capture_output=True, text=True)
    cred = os.path.join(stub, "curl.cred")
    sent = open(cred).read().strip() if os.path.exists(cred) else ""
    return r.returncode, count(stub, "helm.calls"), count(stub, "get.calls"), r.stdout + r.stderr, sent


def case_failures(script, tmp):
    out = []
    for case in CASES:
        rc, pushes, gets, log, _ = run_case(script, case, tmp)
        want = {
            "ok": rc == 0 and pushes == 1 and gets == 0,
            "race": rc == 0 and pushes == 2 and gets == 2 and ("Digest: " + DIGEST) in log,
            "other": rc == 1 and pushes == 1 and gets == 0 and "not retrying" in log,
            "push500": rc == 1 and pushes == 1 and gets == 0 and "not retrying" in log,
            "never": rc == 1 and pushes == 1 and gets == 4 and "still not served" in log,
            "moved": rc == 1 and pushes == 2 and "not " + DIGEST in log,
            "wrongbody": rc == 1 and pushes == 1 and "still not served" in log,
        }[case]
        if not want:
            out.append("case %s: rc %d, %d push(es), %d manifest GET(s); log tail: %s"
                       % (case, rc, pushes, gets, " | ".join(log.strip().splitlines()[-3:])))
    return out


SCRIPT_MUTANTS = [
    ("retry keyed on any error (the race string dropped)", "RACE='failed to perform \"Tag\" on destination: sha256:[0-9a-f]{64}: not found'",
     "RACE='sha256:[0-9a-f]{64}'"),
    ("the ': not found' suffix dropped", ': sha256:[0-9a-f]{64}: not found\'', ': sha256:[0-9a-f]{64}\''),
    ("the Tag operation dropped", "RACE='failed to perform \"Tag\" on", "RACE='failed to perform \"[A-Za-z]*\" on"),
    ("no poll", '  if fetchable "$orphan"; then served=$i; break; fi', "  served=$i; break"),
    ("no digest comparison", '[ "$again" = "$orphan" ] \\\n  || die', 'true \\\n  || die'),
    ("no body hash", '[ "sha256:$(sha256_of "$work/manifest")" = "$digest" ]', "true"),
]

NAME_LINE = """name="$(tar -tzf "$tgz" | awk -F/ 'NR == 1 { print $1 }')\""""
# (case, env, check(rc, pushes, gets, log, sent credential), mutant label, anchor, replacement); label None: no mutant.
ADAPTED = [
    ("creds", {"REGISTRY_USERNAME": USER, "REGISTRY_PASSWORD": TOKEN},
     lambda rc, p, g, log, sent: rc == 0 and p == 2 and sent == "%s:%s" % (USER, TOKEN),
     "reads the source's REGISTRY_USER/REGISTRY_TOKEN",
     '[ -n "${REGISTRY_PASSWORD:-}" ] && cred=(-u "${REGISTRY_USERNAME:-token}:${REGISTRY_PASSWORD}")',
     '[ -n "${REGISTRY_TOKEN:-}" ] && cred=(-u "${REGISTRY_USER:-token}:${REGISTRY_TOKEN}")'),
    ("big", {}, lambda rc, p, g, log, sent: rc == 0 and p == 1 and ("Digest: " + DIGEST) in log, None, None, None),
    ("notgz", {}, lambda rc, p, g, log, sent: rc == 1 and p == 0 and "not a readable chart archive" in log,
     "no message for an unreadable archive",
     NAME_LINE + ' || die "${tgz} is not a readable chart archive"', NAME_LINE),
]


def part1(tmp):
    failures = []
    for f in case_failures(SCRIPT, tmp):
        failures.append("push.sh " + f)
        print("FAIL  script " + f)
    if not failures:
        print("ok    script: %d stand-in cases" % len(CASES))
    src = open(SCRIPT).read()
    killed = 0
    for label, a, b in SCRIPT_MUTANTS:
        if src.count(a) != 1:
            failures.append("cannot plant mutant '%s': its anchor occurs %d times" % (label, src.count(a)))
            print("FAIL  script mutant %s: anchor occurs %d times" % (label, src.count(a)))
            continue
        p = os.path.join(tmp, "mutant.sh")
        open(p, "w").write(src.replace(a, b))
        caught = case_failures(p, tmp)
        if caught:
            killed += 1
            print("ok    script mutant %-52s caught by: %s" % (label, "; ".join(c.split(":")[0] for c in caught)))
        else:
            failures.append("no case notices push.sh with %s" % label)
            print("FAIL  script mutant %-52s NOT CAUGHT" % label)
    # What push.sh changes from its source, each case on the real script, then on its mutant where one applies.
    for name, env, check, label, a, b in ADAPTED:
        rc, pushes, gets, log, sent = run_case(SCRIPT, name, tmp, env)
        good = check(rc, pushes, gets, log, sent)
        print("%s  adapted %-8s rc=%d pushes=%d" % ("ok  " if good else "FAIL", name, rc, pushes))
        if not good:
            failures.append("adapted case %s: rc %d, %d push(es); log tail: %s"
                            % (name, rc, pushes, " | ".join(log.strip().splitlines()[-3:])))
        if label is None:
            continue
        if src.count(a) != 1:
            failures.append("cannot plant mutant '%s': its anchor occurs %d times" % (label, src.count(a)))
            print("FAIL  adapted mutant %s: anchor occurs %d times" % (label, src.count(a)))
            continue
        p = os.path.join(tmp, "mutant.sh")
        open(p, "w").write(src.replace(a, b))
        rc, pushes, gets, log, sent = run_case(p, name, tmp, env)
        caught = not check(rc, pushes, gets, log, sent)
        print("%s  adapted mutant %-46s %s" % ("ok  " if caught else "FAIL", label, "caught by " + name if caught else "NOT CAUGHT"))
        if not caught:
            failures.append("adapted mutant %s not caught by %s" % (label, name))
    return failures, killed


# ---- part 2: the action's step ------------------------------------------------------------------------------------

STEP_ENV = {
    "CHART": "${{ inputs.chart }}",
    "REPOSITORY": "${{ inputs.repository }}",
    "REGISTRY_USERNAME": "${{ inputs.registry-username }}",
    "REGISTRY_PASSWORD": "${{ inputs.registry-password }}",
}


def action_step():
    import yaml
    a = yaml.safe_load(open(ACTION))
    problems = []
    if a.get("runs", {}).get("using") != "composite":
        problems.append("runs.using is not composite")
    if sorted(a.get("inputs", {})) != sorted(["chart", "repository", "registry-username", "registry-password"]):
        problems.append("inputs are %s" % sorted(a.get("inputs", {})))
    for k, v in a.get("inputs", {}).items():
        if v.get("required") is not False or v.get("default") != "":
            problems.append("input %s is not optional with default '': locate mode (release-oci.yaml) passes none" % k)
    if a.get("outputs", {}).get("digest", {}).get("value") != "${{ steps.push.outputs.digest }}":
        problems.append("outputs.digest does not read steps.push.outputs.digest")
    if a.get("outputs", {}).get("path", {}).get("value") != "${{ steps.locate.outputs.path }}":
        problems.append("outputs.path does not read steps.locate.outputs.path, which release-oci.yaml runs")
    steps = [s for s in a.get("runs", {}).get("steps", []) if s.get("id") == "push"]
    if len(steps) != 1:
        problems.append("expected one step with id push, found %d" % len(steps))
        return None, problems
    s = steps[0]
    if s.get("shell") != "bash":
        problems.append("step shell is %r, not bash" % s.get("shell"))
    if s.get("env") != STEP_ENV:
        problems.append("step env is %r, not %r: the cases below would test other wiring than the action's" % (s.get("env"), STEP_ENV))
    return s["run"], problems


# name: (plan case, env overrides, check(rc, pushes, logins, output, log, stub) -> bool, block it tests)
def outputs(path):
    return open(path).read() if os.path.exists(path) else ""


def login_clean(stub, log):
    args = open(os.path.join(stub, "login.args")).read() if os.path.exists(os.path.join(stub, "login.args")) else ""
    stdin = open(os.path.join(stub, "login.stdin")).read() if os.path.exists(os.path.join(stub, "login.stdin")) else ""
    return (stdin == TOKEN and TOKEN not in args and "--password-stdin" in args and args.startswith("reg.stand.in ")
            and ("--username " + USER) in args and TOKEN not in log)


STEP_CASES = [
    ("locate mode: no inputs, nothing pushed", "ok", {"CHART": "", "REPOSITORY": "", "REGISTRY_USERNAME": "", "REGISTRY_PASSWORD": ""},
     lambda rc, p, l, o, log, stub: rc == 0 and p == 0 and l == 0 and o == "", None),
    ("credentials without a chart: fails", "ok", {"CHART": ""},
     lambda rc, p, l, o, log, stub: rc != 0 and p == 0 and l == 0 and "given without chart" in log, "mode-check"),
    ("pushes and outputs the digest", "ok", {},
     lambda rc, p, l, o, log, stub: rc == 0 and p == 1 and l == 1 and o == "digest=%s\n" % DIGEST and login_clean(stub, log),
     "login"),
    ("race: outputs the same digest", "race", {},
     lambda rc, p, l, o, log, stub: rc == 0 and p == 2 and o == "digest=%s\n" % DIGEST, None),
    ("another error: fails, no output", "other", {},
     lambda rc, p, l, o, log, stub: rc != 0 and p == 1 and o == "" and "not retrying" in log, None),
    ("no Digest line: fails, no output", "nodigest", {},
     lambda rc, p, l, o, log, stub: rc != 0 and p == 1 and o == "" and "reported no 'Digest" in log, "digest-check"),
    ("empty password: fails before helm", "ok", {"REGISTRY_PASSWORD": ""},
     lambda rc, p, l, o, log, stub: rc != 0 and p == 0 and l == 0 and o == "" and "input for REGISTRY_PASSWORD is empty" in log,
     "input-check"),
    ("empty user: fails before helm", "ok", {"REGISTRY_USERNAME": ""},
     lambda rc, p, l, o, log, stub: rc != 0 and p == 0 and l == 0 and "input for REGISTRY_USERNAME is empty" in log,
     "input-check"),
    ("repository not oci://: fails before helm", "ok", {"REPOSITORY": "ghcr.io/krateo-blueprints/charts"},
     lambda rc, p, l, o, log, stub: rc != 0 and p == 0 and l == 0 and "must be oci://REGISTRY/PATH" in log, None),
]

LOGIN_ARGV = 'helm registry login "$host" --username "$REGISTRY_USERNAME" --password "$REGISTRY_PASSWORD"'


def run_step(script, case, overrides, tmp):
    stub = tempfile.mkdtemp(dir=tmp)
    tgz = stage(stub, case)
    out = os.path.join(stub, "github_output")
    env = stub_env(stub)
    env.update(CHART=tgz, REPOSITORY=REPO, REGISTRY_USERNAME=USER, REGISTRY_PASSWORD=TOKEN, GITHUB_OUTPUT=out,
               GITHUB_ACTION_PATH=ACTION_DIR)
    env.update(overrides)
    p = os.path.join(stub, "step.sh")
    open(p, "w").write(script)
    # How the runner invokes a composite step with `shell: bash`.
    r = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", p], env=env, capture_output=True, text=True)
    return r.returncode, count(stub, "helm.calls"), count(stub, "login.calls"), outputs(out), r.stdout + r.stderr, stub


def edit_block(script, block, body=None):
    lines = script.split("\n")
    b = [i for i, l in enumerate(lines) if "# BEGIN %s" % block in l]
    e = [i for i, l in enumerate(lines) if "# END %s" % block in l]
    if len(b) != 1 or len(e) != 1 or b[0] >= e[0]:
        return None
    pad = lines[b[0]][:len(lines[b[0]]) - len(lines[b[0]].lstrip(" "))]
    new = [] if body is None else [pad + body]
    return "\n".join(lines[:b[0]] + new + lines[e[0] + 1:])


def part2(tmp):
    failures = []
    script, problems = action_step()
    for pr in problems:
        failures.append("action.yml: " + pr)
        print("FAIL  action.yml " + pr)
    if script is None:
        return failures
    for name, case, ov, check, _ in STEP_CASES:
        rc, p, l, o, log, stub = run_step(script, case, ov, tmp)
        good = check(rc, p, l, o, log, stub)
        print("%s  step  %-42s rc=%d pushes=%d logins=%d output=%r" % ("ok  " if good else "FAIL", name, rc, p, l, o.strip()))
        if not good:
            failures.append("step case %s" % name)
            print("      log: " + log.strip().replace("\n", "\n           "))
    mutants = [
        ("mode-check", "without mode-check", None),
        ("input-check", "without input-check", None),
        ("digest-check", "without digest-check", None),
        ("login", "without login", None),
        ("login", "token in argv", LOGIN_ARGV),
    ]
    for block, label, body in mutants:
        mutant = edit_block(script, block, body)
        if mutant is None:
            failures.append("block %s is not marked exactly once in action.yml's step" % block)
            print("FAIL  block %s is not marked exactly once" % block)
            continue
        tested = [c for c in STEP_CASES if c[4] == block]
        if not tested:
            failures.append("block %s has no case that tests it" % block)
            print("FAIL  block %s has no case that tests it" % block)
        for name, case, ov, check, _ in tested:
            rc, p, l, o, log, stub = run_step(mutant, case, ov, tmp)
            caught = not check(rc, p, l, o, log, stub)
            print("%s  step mutant %-22s %-42s %s" % ("ok  " if caught else "FAIL", label, name,
                                                     "caught" if caught else "NOT CAUGHT: the case does not test this block"))
            if not caught:
                failures.append("step mutant %s not caught by %s" % (label, name))
    return failures


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--stage":
        stage(sys.argv[2], sys.argv[3])
        print(DIGEST if sys.argv[3] in ("ok", "race") else "")
        return 0
    if not os.path.isfile(SCRIPT):
        measurement_failed("%s is missing" % SCRIPT)
    if not os.path.isfile(ACTION):
        measurement_failed("%s is missing" % ACTION)
    for tool in ("bash", "tar"):
        if shutil.which(tool) is None:
            measurement_failed("%s not on PATH" % tool)
    with tempfile.TemporaryDirectory() as tmp:
        failures, killed = part1(tmp)
        failures += part2(tmp)
    if failures:
        for f in failures:
            print("FAIL: " + f)
        return 1
    print("OK: push.sh passes %d stand-in cases, %d/%d script mutants caught, and %d adapted cases with their mutants; "
          "the action's push step passes %d cases and every step mutant is caught"
          % (len(CASES), killed, len(SCRIPT_MUTANTS), len(ADAPTED), len(STEP_CASES)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
