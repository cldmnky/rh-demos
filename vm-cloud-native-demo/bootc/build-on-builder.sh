#!/usr/bin/env bash
# Run as root on the RHEL builder VM after logging in to both registries with Podman.
set -euo pipefail
: "${BOOTC_IMAGE:?Set BOOTC_IMAGE to a writable registry/repository:tag}"
[[ $EUID -eq 0 ]] || { echo 'Run this script as root on the dedicated builder VM.' >&2; exit 1; }
[[ $BOOTC_IMAGE != localhost/* && $BOOTC_IMAGE == */*:* ]] || { echo 'BOOTC_IMAGE must identify a publishable registry/repository:tag.' >&2; exit 1; }
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILDER_IMAGE=${BUILDER_IMAGE:-registry.redhat.io/rhel10/bootc-image-builder:10.2}
OUTPUT_ROOT=${OUTPUT_ROOT:-/var/lib/rocket-ramen-builder}
mkdir -p "$OUTPUT_ROOT"
output=${OUTPUT_DIR:-$(mktemp -d "$OUTPUT_ROOT/image.XXXXXXXX")}
mkdir -p "$output"
[[ -z $(find "$output" -mindepth 1 -maxdepth 1 -print -quit) ]] || { echo 'Build output directory is not empty.' >&2; exit 1; }
auth=()
if [[ -n ${REGISTRY_AUTH_FILE:-} ]]; then auth=(--authfile "$REGISTRY_AUTH_FILE"); fi
podman build "${auth[@]}" -f "$SCRIPT_DIR/Containerfile" -t "$BOOTC_IMAGE" "$SCRIPT_DIR"
podman push "${auth[@]}" "$BOOTC_IMAGE"
podman pull "${auth[@]}" "$BUILDER_IMAGE"
podman run --rm --privileged --pull=never --security-opt label=type:unconfined_t \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$output:/output" "$BUILDER_IMAGE" --type qcow2 "$BOOTC_IMAGE"
[[ -s "$output/qcow2/disk.qcow2" ]] || { echo 'Image builder did not produce a QCOW2 disk.' >&2; exit 1; }
printf 'Bootc OCI image: %s\nQCOW2 disk: %s/qcow2/disk.qcow2\n' "$BOOTC_IMAGE" "$output"
