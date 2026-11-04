# Contributing

This file is an organisation-level default. A repository that publishes its own `CONTRIBUTING.md`
overrides it.

## CI is shared, not copied

Workflows live once in **`krateo-platformops/.github/.github/workflows/`** and every repository
calls them through a small shim in its own `.github/workflows/`. All three organisations —
`krateo-platformops`, `krateo-agentiko`, `krateo-blueprints` — call the same copies. Change the
behaviour there, not in a repository.

Current shared workflows: `security.yml`, `release-notes.yaml`, `release-oci.yaml`,
`lint-docs.yaml`, `preflight-refs.yaml`, `component-image-build.yaml`, `chart-images.yaml`,
`component-go-checks.yaml`, `chart-version-guard.yaml`.

Two things about that repository are load-bearing:

- **It must stay public.** That is the only reason repositories in the other two organisations can
  call it. Making it private breaks CI in two organisations at once.
- **Shims pin `@main`.** An edit to a shared workflow reaches every repository on its next run,
  with no staging. Treat a change there as a change to the whole estate.

## Passing secrets to a shared workflow

`secrets: inherit` **does not cross an organisation boundary**. A shim in `krateo-agentiko` or
`krateo-blueprints` calling a `krateo-platformops` workflow must name each secret explicitly:

```yaml
secrets:
  CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
  RELEASE_FEED_TOKEN: ${{ secrets.RELEASE_FEED_TOKEN }}
```

This failure is silent: the job skips every step and still reports **success**. If a workflow
produces nothing while reporting green, check whether its credentials arrived empty before looking
anywhere else.

## Releases

Releases are **tag-driven**. Push a tag and CI builds and publishes; there is no release button.

Tags carry **no `v` prefix** — `1.6.55`, not `v1.6.55`.

Before tagging, confirm the merge actually landed. A `gh pr merge` that reports a network error may
not have merged, and tagging what you assume is `main` produces a version that is byte-identical to
its predecessor and silently missing the change. Verify with `git rev-list -n1 <tag>` or by grepping
the tag's tree, and check the tag on the **remote** — a stale local tag will lie to `git log`.

## Documentation

`krateo-platformops` and `krateo-agentiko` repositories follow the **Krateo Documentation
Standard** (`DOCS-STANDARD.md` in `krateo-platformops/.github`): an identical core file set in every
repository, enforced by `lint-docs`. What varies is content, never shape.

## Secret scanning

The shared security workflow runs gitleaks with a **shared config passed via `--config`**, which
**overrides** auto-discovery of a repo-local `.gitleaks.toml`. A `.gitleaks.toml` in a repository is
therefore ignored in CI even though it looks like configuration. Per-repository accepted findings go
in a **`.gitleaksignore`** as fingerprints, with a comment saying why each is not a credential.

## What a clean rollout cannot verify

A component documents the paths a healthy rollout **cannot** exercise, and names what verifies them
instead. This is a convention, not a gate: nothing enforces it and there is no template to fill in.

**The problem it exists for.** A quiet roll gets read as evidence. A component that rolls with no
errors, no restarts and no alerts has demonstrated that its happy path works, and nothing else —
but the report says "clean", and the next person treats that as coverage.
**A series of "never caught" results is not evidence.** It is the expected output of a check
whose trigger did not occur, and it is indistinguishable from the output of a check that cannot
fire at all.

Each entry carries four fields:

1. **The path** a clean rollout cannot reach.
2. **Why** it cannot reach it. "No healthy rollout produces this state" is the claim being made, and
   it should be checkable.
3. **The named instrument** that does verify it — a specific test, gate or procedure, not "unit
   tests".
4. **What a green result from that instrument does not cover.**

Field 4 is the one that earns the convention. Without it, the instrument's scope gets inferred by
whoever reads its green tick next, and inferred scope is always wider than real scope. A gate that
proves "if the lookup finds the Secret, the key is reused" is read as "the key is safe"; a suite
that runs against envtest is read as "proven in a cluster".

**Entries live in the component's own `docs/`**, beside the code they describe. Not in a central
list here: a list in this repository goes stale the moment a component changes its tests, and nobody
owns its accuracy.

**Worked example:** `provider-runtime`, `docs/usage.md`, section *"Verifying the rollup during a
provider rollout"*, pinned to the commit so the quote cannot drift from its source:

<https://github.com/krateo-platformops/provider-runtime/blob/c7177bc3a6970ba0c79caf23c3d96d9d1b006433/docs/usage.md>

It has all four fields: the `NotObserved` rollup path, why a healthy rollout never produces it, the
envtest suite and its removal control as the instrument, and what a green run does not cover
(envtest has no kubelet, scheduler or helm).

### Two failure shapes worth naming

**A check satisfied by prose about itself.** A gate that greps a file for a flag's name is satisfied
by the comment above the flag, so deleting the guard and keeping the comment passes. One that
asserts a script "references `statvfs`" is satisfied by a single comment naming it. Substring
searches cannot distinguish a mention from a use, and documentation is made of mentions — the
vocabulary of the check and of the comment come from the same sitting. Parse instead: an AST, or a
real render, does not see comments at all.

**A check satisfied by a true statement about the wrong subject.** This one is worse, because
nothing looks anomalous. A convergence loop in the installer reported `CONVERGED` and exited 0 on a
roll that had applied 7 of 37 releases and doubled the failure count. Its predicate was *"release
count unchanged AND every CompositionDefinition Ready"*, and **both halves were true** —
CompositionDefinition readiness is a property of the per-version controllers, not of whether
any composition's release advanced.

The detail that makes it a pattern rather than a slip: that was the **second** fix to the same
predicate. The first replaced *"count unchanged for three passes"* because it conflated "nothing
moved" with "done". Both "count unchanged" and "CDs Ready" describe the *neighbourhood* of the
releases rather than the releases, so **the repair inherited the defect while looking like its
cure**. The corrected predicate names the releases themselves: every release at the target chart
version, none in a non-`deployed` state.

A prose-satisfied check can be caught by a differential. A wrong-subject check can only be caught by
asking what the predicate's subject is.
