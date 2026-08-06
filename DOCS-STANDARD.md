---
type: Standard
title: Krateo Documentation Standard
description: One identical documentation file set in every krateo-platformops and krateo-agentiko repo — README to docs/ to examples/ — using the Open Knowledge Format so humans and agents consume the same files.
resource: https://cloud.google.com/blog/products/data-analytics/how-the-open-knowledge-format-can-improve-data-sharing
tags: [org-standard, documentation, okf]
timestamp: 2026-08-06T22:00:00Z
---

# Krateo Documentation Standard

Every repo in `krateo-platformops` and `krateo-agentiko` carries **exactly the same
documentation files** — same names, same order, same frontmatter — the way every repo
already carries the same byte-identical `release-oci.yaml`. What varies between repos is
the content, never the shape. The files are markdown with YAML frontmatter (Open
Knowledge Format), so the same bundle serves humans on GitHub and agents through
repo-mcp-server with no translation layer. CI enforces the file set.

## 1. The invariant file set — identical in every repo

```
README.md                 # thin front door, fixed skeleton (§3)
docs/
├── index.md              # the map: what this repo is + links to everything below
├── overview.md           # what it does and how it works (architecture)
├── usage.md              # how to install / consume it
├── configuration.md      # the whole config surface
├── api.md                # the contract it exposes
├── examples.md           # index of examples/, one line each
├── release.md            # how a release ships (runbook)
├── log.md                # curated chronological history
└── llms.txt              # version-pinned agent index of this bundle
examples/
└── <name>/…              # at least one runnable example (§5)
```

No file is ever absent and no repo adds to the **core** set (extra concept files are
allowed *under* `docs/` subdirs — `docs/crds/`, `docs/decisions/` — and are linked from
`index.md`; the core nine never change). A file with nothing to say says so in one
honest line under valid frontmatter — e.g. sse-proxy's `api.md`: "This service exposes
no public API; it proxies SSE streams. See [overview](./overview.md)." — so a reader
(or agent) learns the fact instead of wondering whether the doc is missing.

### The same file, per repo kind

| File | component | library | chart-repo | agent | mcp-server |
|---|---|---|---|---|---|
| `overview.md` | service architecture | package design | what the charts deploy | agent role + prompt architecture | server + tool architecture |
| `usage.md` | installer path + direct `helm install oci://…` | `go get` + minimal code | how the installer consumes it + local `helm template` | how it joins the fleet | how it's attached/registered |
| `configuration.md` | values + env + ConfigMaps | build tags / options | per-chart values wiring | model/prompts/tools values | env + auth + endpoints |
| `api.md` | owned CRDs + HTTP endpoints | exported Go API surface | emitted CompositionDefinitions / CRs | A2A surface + tools used | MCP tools catalog |

## 2. The format (OKF v0.1, adopted as-is)

Every `docs/**/*.md` file has YAML frontmatter; one concept per file; the path is the
concept's identity.

```yaml
---
type: Configuration        # REQUIRED
title: Snowplow configuration
description: Every value, env var and ConfigMap snowplow reads, with defaults.
resource: oci://ghcr.io/krateo-platformops/charts/snowplow   # the live artifact described
tags: [portal, content-api]
timestamp: 2026-08-06T00:00:00Z   # last substantive review
---
```

- **Types for the core files** (fixed): `index.md: Component|Library|ChartRepo|Agent|McpServer`,
  `overview.md: Architecture`, `usage.md: Usage`, `configuration.md: Configuration`,
  `api.md: API`, `examples.md: ExampleIndex`, `release.md: Runbook`. Extension files
  reuse OKF types (`CRD`, `Decision`, `Integration`, `Example`) before inventing new ones.
- **Cross-link with normal markdown links** — the links are the knowledge graph.
- **`resource` points at the real thing**: OCI chart URL, CRD name, image, Go module path — never prose.
- **`timestamp` is a freshness contract**: moves only on substantive review; CI warns
  when it trails the latest release tag (drift detection).
- **`log.md`** is curated history (notable changes, decisions, incidents) — not a
  generated changelog; release notes stay in GitHub Releases.

## 3. README — thin, routing, identical skeleton

The README is the front door, not the encyclopedia. Same sections, same order, ~80 lines:

```markdown
# <repo-name>
One-sentence purpose. Badge row (release, CI).

## What is this
3–6 lines; one link to docs/index.md.

## Install
The ONE canonical way, verbatim commands. (Components: via the installer, plus
direct `helm install oci://…` for standalone. Libraries: `go get`.)

## Configure
Pointer to docs/configuration.md + the 3 most-used settings inline.

## Examples
Pointer to examples/ — one line per example.

## Docs
The docs/ file list with one-line descriptions (mirrors docs/index.md).

## Develop & release
Build/test one-liner + link to docs/release.md.
```

The README links; it never duplicates bundle content.

## 4. Content rules — enhance, fix, preserve

- **Author the missing**: every core file gets real content grounded in the repo's
  artifacts — `configuration.md` from `values.yaml` + `values.schema.json` + deployment
  env, `api.md` from CRDs/exported packages/tool registrations, `usage.md` verified
  against the actual chart. No placeholders.
- **Fix the wrong**: every claim touched is re-grounded in current code; stale paths,
  self-referencing indexes, and dead-org references are corrected in the same PR.
- **Preserve the good**: existing quality prose (architecture docs, wiring docs,
  gotchas) is moved into the bundle (usually as `overview.md` or extension files),
  gains frontmatter, gets drift-fixed — and is not re-authored for style.

## 5. `examples/` — runnable, paired, honest

- Each example: `examples/<name>/` with manifests + a `README.md` of `type: Example`
  stating **preconditions** and the **one command** to apply it.
- Minimum one example per repo. Components: it must work against a stock installer
  deploy. Libraries: a compilable `main.go` or `_test.go` snippet dir.
- `docs/examples.md` indexes them; `llms.txt` lists them.

## 6. `docs/llms.txt` — the agent entry point (kept, formalized)

The 11 repos that already ship `llms.txt` invented the right thing; it becomes uniform:
an ordered, one-line-described list of every file in the bundle + examples, pinned to
the release tag by the release workflow — an agent reading chart X.Y.Z gets X.Y.Z docs.

## 7. Conformance — enforced or it doesn't exist

A shared `lint-docs` job in the canonical CI (pattern: `lint-agents.py`, the
values-schema drift guard), byte-identical in every repo via the `.github` shared
workflow:

1. The exact core file set exists — nothing missing, README sections present in order.
2. Every `docs/**/*.md` has valid frontmatter (`type` from the registry, title, description).
3. All relative markdown links resolve; `llms.txt` entries resolve.
4. Banned strings anywhere in docs: `krateoplatformops/`, `github.com/braghettos`.
5. `examples/` non-empty; every example dir has its `README.md`.
6. Warn (not fail): core-file `timestamp` older than the latest release tag.

## 8. Rollout

1. **Seed**: this standard + `lint-docs` + a `docs-template/` (the nine files with
   frontmatter skeletons) land in `krateo-platformops/.github`; `krateo-agentiko/.github`
   references it.
2. **Pilot**: one repo converted end-to-end and reviewed (calibrates content depth).
3. **Waves** (one PR per repo, workflow-driven, conformance-reviewed before merge):
   components → chart-repos + agents + mcp-servers → libraries.
4. Archived/legacy repos: README reduced to a routing paragraph to the successor; exempt
   from the file set (the only exemption).

## What this deliberately does not do

- No docs website/generator — GitHub rendering is the UI (OKF: format, not platform).
- No per-class file variance — one manifest, everywhere, always.
- No style rewrites of good existing prose.
- No CHANGELOG mandate — `log.md` is curated; release notes stay in GitHub Releases.
