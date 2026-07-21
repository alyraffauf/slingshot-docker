# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89
#
# slingshot — atproto record edge cache (microcosm-rs)
#
# Three independently pinned layers (see README.md):
#   1. base images  -> @sha256 digests below
#   2. source code  -> SLINGSHOT_REF git commit
#   3. cargo crates -> `cargo build --locked` against the workspace Cargo.lock
#
# Every ARG has a working default; override any of them at build time with
# `--build-arg NAME=value` (or run ./pin.sh to refresh the pinned defaults).

# --- pinned base images (override for a rebuild against newer bases) ----------
# Build on the full `rust` image (buildpack-deps): it ships perl + a C toolchain,
# which openssl-sys needs to build its VENDORED static libssl (jetstream enables
# tokio-tungstenite's `native-tls-vendored`). Because OpenSSL is linked
# statically, the runtime needs nothing but glibc + libgcc + CA certs — verified
# with `ldd` (only libc/libm/libgcc_s) — so we use distroless/cc: no apt layer,
# fully digest-pinned, ships ca-certificates and a nonroot (65532) user.
ARG RUST_IMAGE=rust:1-bookworm@sha256:77fac8b98f9f46062bb680b6d25d5bcaabfc400143952ebc572e924bcbedc3fa
ARG RUNTIME_IMAGE=gcr.io/distroless/cc-debian12:nonroot@sha256:b0ae8e989418b458e0f25489bc3be523718938a2b70864cc0f6a00af1ddbd985

########################  build  ##############################################
FROM ${RUST_IMAGE} AS build

# --- pinned source ------------------------------------------------------------
ARG SLINGSHOT_REPO=https://tangled.org/microcosm.blue/microcosm-rs
ARG SLINGSHOT_REF=3137b07d5268812d2de0f3177664be92196994d8
ARG CARGO_PKG=slingshot

WORKDIR /src
RUN git clone "${SLINGSHOT_REPO}" . \
 && git checkout --detach "${SLINGSHOT_REF}"

# rust-toolchain.toml upstream pins components but no channel; drop it so the
# build uses the (digest-pinned) image's stable toolchain. It's recent enough
# for edition 2024, which slingshot requires.
RUN rm -f rust-toolchain.toml

# --locked: refuse to build if Cargo.lock would change. Every crates.io dep is
# verified against its sha256 in the workspace Cargo.lock; the atrium git deps
# are pinned to an exact rev by that lock as well.
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked -p "${CARGO_PKG}" \
 && cp "target/release/${CARGO_PKG}" /usr/local/bin/slingshot

# Pre-create the cache dir so the shell-less runtime can COPY it in already
# owned by the nonroot (65532) user.
RUN install -d -o 65532 -g 65532 /out/cache

########################  runtime  ############################################
FROM ${RUNTIME_IMAGE} AS runtime

COPY --from=build /usr/local/bin/slingshot /usr/local/bin/slingshot
COPY --from=build --chown=65532:65532 /out/cache /cache
# The `/` route serves ./static/index.html relative to CWD, so ship static/ and
# run from /app. (The API on /xrpc works regardless; a TCP probe is still the
# most robust k8s readiness check.)
COPY --from=build /src/slingshot/static /app/static
WORKDIR /app

# Runtime config is entirely env-driven (clap `env = "SLINGSHOT_*"`). These are
# sensible non-secret defaults; override any of them in your orchestrator.
# NOTE: the disk-cache vars are literally SLINGSHOT_*_CACHE_DISK_DB upstream
# (a typo for GB in the source) — the value is still in gigabytes.
# Vendored OpenSSL's compiled-in cert dir points at the (now-gone) build path,
# so point it at distroless's CA bundle explicitly.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_DIR=/etc/ssl/certs \
    SLINGSHOT_BIND=0.0.0.0:8080 \
    SLINGSHOT_CACHE_DIR=/cache \
    SLINGSHOT_JETSTREAM=wss://jetstream1.us-east.bsky.network/subscribe \
    SLINGSHOT_RECORD_CACHE_MEMORY_MB=256 \
    SLINGSHOT_RECORD_CACHE_DISK_DB=2 \
    SLINGSHOT_IDENTITY_CACHE_MEMORY_MB=256 \
    SLINGSHOT_IDENTITY_CACHE_DISK_DB=2

# 8080 = HTTP API, 8765 = prometheus metrics (only served with --collect-metrics)
EXPOSE 8080 8765
VOLUME ["/cache"]

# uid/gid 65532 to match the usual k8s nonroot convention; mount your PVC with
# fsGroup: 65532 so it's writable.
USER nonroot
ENTRYPOINT ["/usr/local/bin/slingshot"]
