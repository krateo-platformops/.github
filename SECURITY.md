# Security Policy

This policy applies to every repository in this organisation unless a repository publishes its
own `SECURITY.md`, which takes precedence.

## Reporting a vulnerability

**Please do not open a public issue for a suspected vulnerability.**

Use GitHub's private vulnerability reporting on the affected repository:
**Security → Advisories → Report a vulnerability**. If it is not enabled there, report it on any
repository in this organisation that has it enabled and say which repository is affected.

A report is most useful when it says what an actor who holds a given permission can end up doing —
the permission they start from, the resource they reach, and what leaves the cluster. A runnable
manifest is welcome but never required; please hold it back from anywhere public.

If the affected component is vendored from an upstream project, report it to that project's own
security channel as well as here. Fixing it in our chart does not fix it for their other users.

## Supported versions

Fixes land on `main` and ship in the next tagged release. Only the latest minor is supported.

## What tends to matter in this codebase

Krateo components reconcile custom resources, and two properties shape most interesting reports:

- **Components act with their own identity.** A controller's reads and writes use its
  ServiceAccount, not the identity of whoever authored the custom resource. Several hold
  cluster-wide `get` because a custom resource may reference arbitrary kinds.
- **Several are egress paths.** A resource that names a remote — a git repository, a registry, an
  OTLP endpoint — means anything the component can read and serialise can leave the cluster.

Together those make "who may create resource X in namespace Y" a meaningful security question, and
usually the most useful thing a report can pin down.

## Secret scanning

Every repository runs gitleaks through the shared security workflow. It uses a **shared config**
passed with `--config`, which **overrides** any repo-local `.gitleaks.toml` — a repo-local
`.gitleaks.toml` is silently ignored in CI. Per-repository accepted findings belong in a
**`.gitleaksignore`** (fingerprints), which is honoured. Add an entry only for a finding you have
audited, and say in a comment why it is not a credential.
