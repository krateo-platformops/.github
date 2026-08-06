# <repo-name>

<One-sentence purpose.> <!-- badges: release, CI -->

## What is this

<3–6 lines: what it does, where it sits in the platform.>
Full picture: [docs/index.md](docs/index.md).

## Install

<THE one canonical way, verbatim commands. Components: via the installer, plus
direct `helm install oci://ghcr.io/<org>/charts/<name> --version X.Y.Z` for
standalone. Libraries: `go get github.com/<org>/<name>`.>

## Configure

See [docs/configuration.md](docs/configuration.md). Most used:

| Setting | Default | Effect |
|---|---|---|
| `<key>` | `<default>` | <one line> |

## Examples

- [examples/minimal](examples/minimal) — <one line>

## Docs

- [docs/index.md](docs/index.md) — the map
- [docs/overview.md](docs/overview.md) — what it does and how it works
- [docs/usage.md](docs/usage.md) — how to install / consume it
- [docs/configuration.md](docs/configuration.md) — the whole config surface
- [docs/api.md](docs/api.md) — the contract it exposes
- [docs/examples.md](docs/examples.md) — examples index
- [docs/release.md](docs/release.md) — how a release ships
- [docs/log.md](docs/log.md) — curated history

## Develop & release

`<build/test one-liner>` — release runbook: [docs/release.md](docs/release.md).
