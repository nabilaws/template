# Release

This guide covers releases of your instance: the version format, cutting a
release with `make release`, what `release.yml` builds, tests, and publishes,
the repository settings it reads, the image names, and building and testing
the images locally with `make package` and `make smoke`. It is for the
developer who ships your instance. It is the one guide for releases and images;
deployment of a release is in [deploy.md](deploy.md).

## 1. Prerequisites

- A checkout on which `make install` has run.
- The instance repository on GitHub, with `origin` pointing at it and GitHub
  Actions enabled.
- The commit to release is on `origin/main`, and the working tree is clean.
- Optional: the repository settings in Section 5, to push the images and to
  seed the desktop bundles.

## 2. Version format

A release version is the git tag, the image tag, and the desktop bundle name:

```
^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$
```

| Matches | Does not match |
|---|---|
| `v0.1.0`, `v1.2.0`, `v10.0.12`, `v1.3.0-rc.1` | `1.2.0`, `v1.2`, `v1.2.0-rc.0`, `v1.2.0-rc1`, `v1.2.0-beta.1` |

Versions are ordered by semantic versioning: `vX.Y.Z-rc.N` is older than
`vX.Y.Z`, and the `N` values compare as numbers (`-rc.10` is newer than
`-rc.2`). A version with `-rc.N` is published as a GitHub pre-release; a
version without it is published as a normal release.

## 3. Cut a release

1. Merge the work to `main` and update your checkout.
2. Run `make release` with the new version:

   ```sh
   make release VERSION=v0.3.0
   ```

3. Follow the `release` workflow run in the repository's Actions tab.

`make release` runs `scripts/release.sh`. It checks these preconditions in
order, and the first one that fails exits 1 without creating a tag:

1. `VERSION` matches the version format.
2. The working tree is clean, untracked files included.
3. `HEAD` is an ancestor of `origin/main`, after `git fetch --tags`.
4. The tag exists neither locally nor on `origin`.
5. `VERSION` is newer than every existing release tag.
6. `make check` passes.

It then creates an annotated tag and pushes it. When the push fails, it
deletes the local tag.

| Variable | Default | Meaning |
|---|---|---|
| `RELEASE_REMOTE` | `origin` | The remote to fetch from and push the tag to. |
| `RELEASE_BRANCH` | `main` | The branch that `HEAD` must be an ancestor of. |
| `RELEASE_CHECK_TARGET` | `check` | The `make` target run as the last precondition. |

## 4. What `release.yml` does

`release.yml` runs when a tag that starts with `v` is pushed:

1. **Version check.** The tag matches the version format and its commit is on
   `main`. A tag with `-rc.N` is marked as a pre-release.
2. **Full gate.** `full-check.yml`: the light gate plus the screen suites,
   the composed typecheck, and the database lanes (Section 9).
3. **Images.** `make package VERSION=<v>` builds `api`, `web`, and `worker`
   for the runner's own platform into its local image store. The job runs on
   `RELEASE_RUNNER` (default `ubuntu-latest`, which is `linux/amd64`).
4. **Smoke test.** `make smoke VERSION=<v>` (Section 7.2).
5. **Push.** Only when the repository variable `REGISTRY` is set: when
   `REGISTRY_PASSWORD` is set, logs in to the registry host, the part of
   `REGISTRY` before the first `/`, with `REGISTRY_USERNAME` and
   `REGISTRY_PASSWORD` (password on standard input); otherwise it uses the
   runner's own registry login. It pushes the images with the tag `<v>` for every platform in `PLATFORMS`, and
   logs out. The list of pushed images with their digests goes to the build
   artifact `margince-images-<v>`.
6. **Desktop bundles.** `desktop-macos.yml` for Apple silicon and for Intel,
   and `desktop-windows.yml` (Section 8).
7. **GitHub Release.** Created after every job above passes, with the three
   zip files attached: `margince-macos-apple-silicon-<v>.zip`,
   `margince-macos-intel-<v>.zip`, and `margince-windows-<v>.zip`. The notes
   list the core version, the instance commit, and the pushed image digests,
   or `images were not pushed: REGISTRY is not set`.

Only the runner's own platform is smoke-tested. Other platforms in
`PLATFORMS` are pushed without their own smoke test, so run the release on a
runner of the architecture you deploy (the standard stacks' runners have their
stack's architecture).

A failed run publishes no release. Fix the cause, then delete the tag and cut
the release again:

```sh
git push --delete origin v0.3.0 && git tag -d v0.3.0
make release VERSION=v0.3.0
```

A run started again after the release exists replaces the release's zip files
and notes instead of failing.

## 5. Repository settings

`release.yml` works without any repository setting: it builds and
smoke-tests the images without pushing them, and builds the desktop bundles
without demo data. Someone with admin rights on the repository can set:

| Setting | Kind | Default | Effect |
|---|---|---|---|
| `REGISTRY` | variable | unset | The image name prefix, for example `docker.io/acme` or `registry.example.com/acme`. It must start with the registry host. Unset: the images are not pushed. |
| `REGISTRY_USERNAME` | secret | none | The user name for the registry login. |
| `REGISTRY_PASSWORD` | secret | none | The password or token for the registry login. Never printed. Unset: no login; the runner's own registry login is used (a self-hosted runner, below). |
| `PLATFORMS` | variable | `linux/amd64,linux/arm64` | Comma-separated platforms of the pushed images. The default serves both architectures; set `linux/amd64` or `linux/arm64` alone for a faster build. The smoke test runs the runner's own platform. |
| `RELEASE_RUNNER` | variable | `ubuntu-latest` | The runner label of the `images` job: the build, the smoke test and the push. Set it to a self-hosted runner's label to build inside the deployment's network. |
| `DATASET_REPOSITORY` | variable | unset | The demo dataset repository that the desktop workflows check out and seed. |
| `DATASET_DEPLOY_KEY` | secret | unset | An SSH key with read access to `DATASET_REPOSITORY`. Without it or the variable, the bundles ship without demo data. |

Use the same `REGISTRY` value when you deploy, so that `make deploy` names the
same images ([deploy.md](deploy.md#53-credentials)).

**Building inside the deployment's network.** With `RELEASE_RUNNER` set to
the label of a self-hosted runner (the standard stacks in
`deploy/production/` provide one), the `images` job runs there: the code is
built, smoke-tested and pushed inside the cloud network, and the runner logs
in to the private registry with its cloud identity, so no registry password is
stored in GitHub. Leave `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` unset in
that case. The other jobs keep running on GitHub's runners. Register a
self-hosted runner only on a private repository: on a public one, a pull
request from anyone could run code on it.

**Architectures.** Core's `Dockerfile` cross-compiles, so any runner builds
every platform in `PLATFORMS`. The default, `linux/amd64,linux/arm64`,
deploys on either architecture; the smoke test covers the runner's own platform, the
other platforms are pushed without their own smoke test.

## 6. Image names and labels

The image repository is the instance's `name` from `instance.yaml`, with
`REGISTRY` in front of it when `REGISTRY` is set:

| `REGISTRY` | Images |
|---|---|
| unset | `<name>/api`, `<name>/web`, `<name>/worker` |
| `registry.example.com/acme` | `registry.example.com/acme/<name>/api`, `/web`, `/worker` |

`REGISTRY` is read from the environment of `make package`, `make smoke`,
`make local-up`, and `make deploy`; it is not stored in `instance.yaml`.

Every image carries these OCI labels:

| Label | Value |
|---|---|
| `com.margince.instance.name` | `name` from `instance.yaml`. |
| `com.margince.instance.revision` | The instance commit. |
| `com.margince.core.revision` | The `core/` commit. |
| `com.margince.core.version` | `core` from `instance.yaml`. |
| `com.margince.instance.units` | The units in `extensions/`. |

```sh
docker inspect <repo>/api:<v> --format '{{json .Config.Labels}}'
```

## 7. Build and test the images locally

### 7.1 `make package`

```sh
make package VERSION=v0.3.0
```

`make package` stages the units and builds the images with core's
`Dockerfile` and `docker-bake.hcl`. By default it loads them into the local
Docker image store.

| Variable | Default | Meaning |
|---|---|---|
| `VERSION` | the tag at `HEAD`, else the short commit | The image tag. `make smoke`, `make local-up`, and `make deploy` need a release version. |
| `ROLE` | all three | `api`, `web`, or `worker`, to build one image. |
| `REGISTRY` | unset | The registry prefix (Section 6). |
| `REPO` | `<REGISTRY>/<name>` | Overrides the whole image repository. |
| `PLATFORMS` | empty (the native platform) | Comma-separated platforms, read by core's bake file. A local load holds one platform. |
| `PUSH` | unset | `PUSH=1` pushes the images for every platform in `PLATFORMS` instead of loading them. Requires `REGISTRY`. |
| `ALLOW_DIRTY` | unset | `ALLOW_DIRTY=1` builds from a working tree with uncommitted changes. |

### 7.2 `make smoke`

```sh
make smoke VERSION=v0.3.0
```

`make smoke` runs the same check as `release.yml`, on images that
`make package` has loaded:

1. Creates a private Docker network with PostgreSQL
   (the images the host adapter pins in `scripts/deploy/host/compose.yaml`, which match core's `docker-compose.dev.yml`), with random passwords
   and keys that never appear on a command line.
2. Runs `core/scripts/deploy/db-bootstrap.sql` once as the superuser.
3. Starts `api` and waits until `/readyz` answers.
4. Starts `worker` and `web`. `web` must answer `/`, and `worker` must still
   run after `SMOKE_SETTLE` seconds.
5. Removes every container and the network, on success and on failure. On
   failure it first prints the last 100 log lines of each Margince container.

| Variable | Default | Meaning |
|---|---|---|
| `SMOKE_TIMEOUT` | 180 | Seconds to wait for PostgreSQL, for `api /readyz`, and for `web /`, each. |
| `SMOKE_SETTLE` | 10 | Seconds the worker must keep running. |
| `REGISTRY` | unset | The registry prefix of the image names (Section 6). |

The smoke test runs `api` with `MARGINCE_ENV=test`, so it needs no license.
To run the images as a full local stack, use `make local-up VERSION=<v>` (see
the [README](../README.md#run-margince-default-on-your-computer)).

## 8. Desktop bundles

`desktop-macos.yml` and `desktop-windows.yml` are reusable workflows that
`release.yml` calls. They are copies of core's workflows, because a workflow
cannot use a file inside a submodule; update them from `core/.github/workflows/`
when core's versions change. They do not run on pull requests. To test one
without a release, start it by hand:

```sh
gh workflow run desktop-windows.yml --ref main
```

A build started this way is named after its commit. Locally, `make desktop`
builds the macOS folder; there is no local Windows build. See
[desktop-build.md](desktop-build.md) for building, installing, and running a
folder.

Each folder carries `BUILD-INFO.txt` and `runtime/build-info.json`, which name
the version, the platform, the instance and core commits, the units, and the
demo dataset commit. The release workflows pass the version and the commits
in. The fields and their values are in
[desktop-build.md](desktop-build.md#8-build-information).

The desktop workflows check out the dataset's default branch, not a pinned
commit. A second run of a release on the same tag can therefore ship
different demo data; the `dataset` line shows which.

## 9. CI workflows

| Workflow | Runs on | Content |
|---|---|---|
| `ci.yml` | pull requests, pushes to `main` | The light gate: `check-instance`, `check-template`, `check-composition`, `check-manifests`, `build`, `test-extensions`, `arch`, `ext-imports`, `fe-ds-gates`, `lint`, `drift`, `check-docs`, `test-scripts`, `core-check-pin`, the clean-submodule check, `secret-scan`, and `test-secret-scan`. |
| `lifecycle.yml` | pull requests, pushes to `main`, by hand | `make test-lifecycle`. In your instance every step after the first check is skipped. |
| `release.yml` | pushed `v*` tags | Section 4. |
| `full-check.yml` | called by `release.yml` | The light gate plus `fe-test-ext`, `fe-typecheck-composed`, `check-ext-migrations`, and `test-integration-ext`. |
| `desktop-macos.yml`, `desktop-windows.yml` | called by `release.yml`, by hand | Section 8. |
| `deploy.yml` | by hand | [deploy.md](deploy.md#6-deploy-from-github-actions). |

A green pull request means that the composition builds and passes the light
gate, not that the tree can be released. `make ci` runs the full gate
locally.

## Related guides

- [deploy.md](deploy.md): deploy a released version.
- [license.md](license.md): the license a production deployment needs.
- [trial.md](trial.md): a trial desktop bundle.
- [desktop-build.md](desktop-build.md): the desktop folder.
- [troubleshooting.md](troubleshooting.md): release and packaging errors.
