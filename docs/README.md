# Documentation

The guides for creating, developing, releasing, and deploying a Margince
instance. Start with the [README](../README.md) for the requirements, the quick
start, and the command overview. Each topic has one guide; the other guides
link to it.

## Getting started

| Guide | Purpose |
|---|---|
| [Create your instance](create-an-instance.md) | Create your instance, receive template changes, upgrade core, and add instance-only `make` targets. |
| [Adding an extension](adding-an-extension.md) | Create, compose, and test a unit in `extensions/`. |

## Day to day

| Guide | Purpose |
|---|---|
| [Desktop build](desktop-build.md) | Build, install, run, and seed the macOS desktop folder. |
| [Contributing to core](contributing-to-core.md) | Change `core/` on a contribution branch and open a pull request to `margince/margince`. |
| [Troubleshooting](troubleshooting.md) | Known error messages, their causes, and their fixes. |

## Release and deploy

| Guide | Purpose |
|---|---|
| [Release](release.md) | Cut a release with `make release`, and what `release.yml` builds, tests, and publishes. Image names, `make package`, and `make smoke`. |
| [Deploy](deploy.md) | The deployment contract, `make deploy-init`, the `host` adapter, the `hook` adapter, and `deploy.yml`. |
| [Cloud infrastructure](../deploy/production/README.md) | Terraform for Azure and AWS: a light flavour (one VM with the `host` adapter) and a standard flavour (managed containers behind a WAF), the same method on both clouds, with architecture diagrams. |
| [License](license.md) | Obtain a trial or production license with `make license`, and the license service API. |
| [Trial](trial.md) | Build a trial desktop bundle with a trial license with `make trial`. |

## Reference

| Guide | Purpose |
|---|---|
| [Glossary](glossary.md) | The terms this repository uses. |

## Design and plans

| Document | Content |
|---|---|
| [Client instance template: design](superpowers/specs/2026-09-24-client-instance-template-design.md) | Goals, repository responsibilities, path ownership, workflows, versioning, and implementation status (Section 13). |
| [Issue breakdown](superpowers/plans/2026-09-24-issue-breakdown.md) | Every issue, its scope, its completion criterion, and its status. |
| [Template foundation (T1, T2)](superpowers/plans/2026-09-24-template-foundation.md) | Tooling import, `instance.yaml`, and the Go CLI. |
| [Instance basics (T3 to T6, T11)](superpowers/plans/2026-09-25-instance-basics.md) | Neutral scripts, `instance.mk`, the core pin by tag, the drift check, `make new-instance`. |
| [Deploy (T9)](superpowers/plans/2026-09-25-deploy.md) | The deployment contract and the `hook` adapter. |
| [Lifecycle CI (T10, part 1)](superpowers/plans/2026-09-25-lifecycle-ci.md) | `make test-lifecycle` and `lifecycle.yml`. |
| [Public template (T7, T8, T10 part 2, T12, T13, T15, T16)](superpowers/plans/2026-09-28-public-template.md) | The public-only rule, release, licensing, trial, the `host` adapter, and the guides. |
| [Default setup (T17)](superpowers/plans/2026-09-29-default-setup.md) | Generated instance keys and admin password, file storage, the license check, `make deploy-init`, and the local stack. |
| [Default VM deployment (T18)](superpowers/plans/2026-09-29-default-vm.md) | The default `production` environment in `deploy/production/`. |

`docs/superpowers/` holds the design history: `specs/` has one file per design
(`YYYY-MM-DD-<topic>-design.md`) and `plans/` has the issue breakdown and the
implementation plans. `docs/client/` is instance-owned and holds a client's own
documentation; the template has none.
