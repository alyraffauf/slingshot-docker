# slingshot-docker

A hash-pinned, env-configurable container image for
[slingshot](https://tangled.org/microcosm.blue/microcosm-rs/tree/main/slingshot). 
Upstream ships a Rust binary with no official image, so this builds one.

## Build

```sh
./build.sh                                        # -> slingshot:dev (local)
IMAGE=atcr.io/tranquil.farm/slingshot TAG=latest PUSH=1 ./build.sh
```

`build.sh` honors `ENGINE` (docker/podman/buildah), `IMAGE`, `TAG`, `PUSH`, and
`SLINGSHOT_REF`.

## Run (local smoke test)

```sh
docker run --rm --ulimit nofile=65536:65536 -p 8080:8080 \
  slingshot:dev --jetstream us-east-1 --cache-dir /cache
```

The `--ulimit` is **required**: foyer's identity cache opens many files and dies
with `Too many open files (os error 24)` under Docker's default 1024 fd limit.

## Pinning (three layers)

Everything that goes into the image is pinned, and none of it depends on
mutable tags:

1. **Base images** — `FROM …@sha256:` digests for both the Rust build image and
   the distroless/cc runtime.
2. **Source** — the build does `git checkout <SLINGSHOT_REF>` at an exact
   commit, not a branch.
3. **Cargo crates** — `cargo build --locked` fetches every dependency and
   verifies it against the sha256 checksum recorded in the workspace
   `Cargo.lock`, and hard-fails if the lock would change.

## Runtime configuration (env vars)

slingshot reads all config from `SLINGSHOT_*` env vars. Image defaults:

| Env var | Default | Notes |
|---|---|---|
| `SLINGSHOT_JETSTREAM` | `wss://jetstream1.us-east.bsky.network/subscribe` | required upstream; default lets it run out of the box |
| `SLINGSHOT_BIND` | `0.0.0.0:8080` | HTTP API |
| `SLINGSHOT_CACHE_DIR` | `/cache` | mount a volume here |
| `SLINGSHOT_RECORD_CACHE_MEMORY_MB` | `256` | |
| `SLINGSHOT_RECORD_CACHE_DISK_DB` | `2` | GB, despite the `_DB` name (upstream typo) |
| `SLINGSHOT_IDENTITY_CACHE_MEMORY_MB` | `256` | |
| `SLINGSHOT_IDENTITY_CACHE_DISK_DB` | `2` | GB |
| `SLINGSHOT_PLC_DIRECTORY` | (upstream default) | |
| `SLINGSHOT_JETSTREAM_NO_ZSTD` | unset | set to `true` to disable zstd |
| `SLINGSHOT_COLLECT_METRICS` | unset | set `true` to serve prometheus metrics |
| `SLINGSHOT_BIND_METRICS` | `[::]:8765` | only with metrics enabled |
| `SLINGSHOT_HEALTHCHECK` | unset | optional healthcheck URL |

ACME env vars (`SLINGSHOT_ACME_*`) are intentionally left unset: TLS is
terminated at the ingress, so the container serves plain HTTP.

## Notes

- Runs as nonroot (uid/gid **65532**). Mount the cache volume with
  `fsGroup: 65532` so it's writable.
- Ports: **8080** (HTTP), **8765** (metrics, opt-in).
- Runtime is `gcr.io/distroless/cc-debian12:nonroot`. OpenSSL is pulled in
  (`cargo tree -i openssl-sys`) but built **vendored/static** because
  `jetstream` enables `tokio-tungstenite`'s `native-tls-vendored`, so the binary
  links no system libssl (`ldd` shows only glibc/libgcc). `SSL_CERT_FILE` is set
  so the vendored OpenSSL finds distroless's CA bundle. If you'd rather not
  vendor, switch `RUNTIME_IMAGE` to a pinned `debian:bookworm-slim` and add
  `ca-certificates libssl3` (and drop `native-tls-vendored`); `./pin.sh` handles
  that digest too.
- **Health probes:** slingshot's `--healthcheck` flag is an *outbound* ping to a
  URL (healthchecks.io-style), not an HTTP endpoint. There's no `/health`
  route — use a **TCP probe on 8080** for k8s liveness/readiness. `/` serves a
  static page (shipped in the image) if you prefer an HTTP GET check.
- **No capability needed:** upstream's `setcap CAP_NET_BIND_SERVICE` note is
  only for binding low ports on bare metal. This image binds 8080, so it runs
  fine as nonroot with no added capabilities.
- **File descriptors (required):** the identity cache opens many files.
  Confirmed to crash with `Too many open files` under a 1024 fd limit. Raise it:
  `--ulimit nofile=65536:65536` for docker/podman. In k8s, containerd's default
  `LimitNOFILE` is usually ~1048576 (fine), but if you see fd exhaustion, bump it
  at the node/runtime level — there's no per-pod nofile field.
