# slingshot-docker

Container image for [Slingshot](https://tangled.org/microcosm.blue/microcosm-rs/tree/main/slingshot), an atproto record edge cache.
The image builds Slingshot from a pinned commit of `microcosm-rs`.
Renovate tracks upstream `main` and opens a pull request when that commit changes.

## Run the published image

```sh
docker run -d --name slingshot \
	--ulimit nofile=65536:65536 \
	-p 8080:8080 \
	-v slingshot-cache:/cache \
	ghcr.io/alyraffauf/slingshot:latest
```

Open `http://localhost:8080/` to check the static page. The API is under `/xrpc`.
Raise the file descriptor limit as shown above. The identity cache can exhaust Docker's 1024-descriptor limit.

The image runs as UID and GID `65532` and stores its cache in `/cache`.
For bind mounts, give that user write access. For Kubernetes volumes, set `fsGroup: 65532`.
The runtime is distroless and has no shell. Terminate TLS at your ingress or reverse proxy.

## Update a running container

Renovate updates the build inputs in this repository. Each merge to `master` builds and publishes:

- `ghcr.io/alyraffauf/slingshot:latest`
- `ghcr.io/alyraffauf/slingshot:sha-<full-repository-commit>`

Pull the image, then recreate your container with the same configuration and cache volume:

```sh
docker pull ghcr.io/alyraffauf/slingshot:latest
docker stop slingshot
docker rm slingshot
```

Run the command from the previous section again. The named cache volume survives container removal.
Pulling an image or restarting an existing container does not replace that container's image.
Use a `sha-...` tag or an image digest when you need a specific published build.
The SHA tag identifies a commit in this repository, not the upstream Slingshot commit.

## Dependency updates

[renovate.json](renovate.json) covers the following build inputs:

| Input | Pin | Renovate tracks |
|---|---|---|
| Slingshot source and static files | `SLINGSHOT_REF` in `Dockerfile` | The latest commit on upstream `microcosm-rs` `main`, through the `git-refs` custom manager |
| Rust compiler and build tools | `RUST_IMAGE` digest | `rust:1-bookworm` |
| Runtime libraries and CA certificates | `RUNTIME_IMAGE` digest | `gcr.io/distroless/cc-debian12:nonroot` |
| Dockerfile frontend | `# syntax=` digest | `docker/dockerfile:1` |
| GitHub Actions | Action commit digests | Version tags and their digests |
| GitHub-hosted runner | `runs-on` version | Ubuntu runner releases |

Docker tags select the release line to monitor. The digest selects the exact image used to build.
The Rust and runtime images currently use Debian 12. A move to another Debian release requires a coordinated change to both image names.

Slingshot's Rust crates come from the `Cargo.lock` at the pinned upstream commit.
`cargo build --locked` preserves those versions and fails if the lockfile needs to change.
Renovate in this repository does not update individual crates in the remotely cloned workspace.
Crate updates arrive when upstream updates its manifests and lockfile, then Renovate advances `SLINGSHOT_REF` here.
A new compiler or base image alone does not update Slingshot or its crates.

Renovate is configured to automerge dependency PRs after GitHub's required `Build and push` check passes.
Every PR runs that check without publishing. Merges to `master` publish the image.

To check update status, open the [Dependency Dashboard](https://github.com/alyraffauf/slingshot-docker/issues/3).
Its detected dependencies should include `microcosm-rs main@<commit>` under `regex`, plus the Docker and GitHub Actions dependencies.
Compare `SLINGSHOT_REF` with upstream when you want to check the source directly:

```sh
git ls-remote https://tangled.org/microcosm.blue/microcosm-rs refs/heads/main
```

## Build locally

```sh
./build.sh
```

This builds `slingshot:dev` using the defaults in `Dockerfile`.
Run it with the same options as the published image.
`build.sh` accepts these environment variables:

| Variable | Default | Purpose |
|---|---|---|
| `ENGINE` | `docker` | `docker`, `podman`, or `buildah` |
| `IMAGE` | `slingshot` | Image name without a tag |
| `TAG` | `dev` | Image tag |
| `PUSH` | `0` | Set to `1` to publish with your configured registry credentials |
| `SLINGSHOT_REF` | Dockerfile default | Override the upstream source commit for this build |

For example, to build with Podman:

```sh
ENGINE=podman ./build.sh
```

To override base images or other Dockerfile arguments, invoke your build engine directly with `--build-arg NAME=value`.
CI publishes Linux AMD64 images. Other architectures require separate build validation.

## Runtime configuration

Set `SLINGSHOT_*` environment variables with `docker run -e NAME=value`, or pass CLI flags after the image name.
CLI flags override environment variables. For the available flags, run:

```sh
docker run --rm ghcr.io/alyraffauf/slingshot:latest --help
```

The image sets the following defaults:

| Variable | Default | Purpose |
|---|---|---|
| `SLINGSHOT_JETSTREAM` | `wss://jetstream1.us-east.bsky.network/subscribe` | Jetstream source |
| `SLINGSHOT_BIND` | `0.0.0.0:8080` | HTTP listener |
| `SLINGSHOT_CACHE_DIR` | `/cache` | Disk cache directory |
| `SLINGSHOT_RECORD_CACHE_MEMORY_MB` | `256` | Record memory cache, in MB |
| `SLINGSHOT_RECORD_CACHE_DISK_DB` | `2` | Record disk cache, in GB |
| `SLINGSHOT_IDENTITY_CACHE_MEMORY_MB` | `256` | Identity memory cache, in MB |
| `SLINGSHOT_IDENTITY_CACHE_DISK_DB` | `2` | Identity disk cache, in GB |

The `_DISK_DB` spelling is an upstream typo. Both values are in gigabytes.
The image also points `SSL_CERT_FILE` and `SSL_CERT_DIR` at the runtime CA certificates so vendored OpenSSL can verify HTTPS connections.

These optional settings use upstream defaults unless you override them:

| Variable | Default | Purpose |
|---|---|---|
| `SLINGSHOT_PLC_DIRECTORY` | `https://plc.directory` | PLC directory |
| `SLINGSHOT_JETSTREAM_NO_ZSTD` | `false` | Set to `true` to disable Jetstream zstd compression |
| `SLINGSHOT_COLLECT_METRICS` | `false` | Set to `true` to enable Prometheus metrics |
| `SLINGSHOT_BIND_METRICS` | `[::]:8765` | Metrics listener when collection is enabled |
| `SLINGSHOT_HEALTHCHECK` | Unset | URL for outbound healthcheck pings |

Publish port `8765` if you enable metrics and need access outside the container.
For IPv4 metrics access, set `SLINGSHOT_BIND_METRICS=0.0.0.0:8765`.

`SLINGSHOT_HEALTHCHECK` sends outbound pings. Slingshot has no `/health` endpoint.
Use a TCP probe on port `8080`, or an HTTP GET on `/` to check that the server responds.
Neither check proves that Jetstream data is current.
