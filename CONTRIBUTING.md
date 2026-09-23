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
`component-go-checks.yaml`.

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
