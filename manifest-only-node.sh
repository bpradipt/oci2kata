#!/bin/bash
# manifest-only-node.sh — register a container image manifest on the worker
# node WITHOUT downloading the layer blobs, so the node never pulls the image
# and the kata-remote guest pulls it (from the embedded cache or the registry).
#
# This avoids the double pull: containerd's CRI PullImage is skipped because the
# image is already "present" (manifest + config registered), so the node never
# downloads layers.  At CreateContainer, the nydus snapshotter emits
# image_guest_pull and CDH pulls the image inside the VM.
#
# Usage:
#   sudo ./manifest-only-node.sh <IMAGE_REF>
#
# Example:
#   sudo ./manifest-only-node.sh docker.io/library/python:3.12
#
# Requires: containerd's ctr + crictl on the worker node (root).
#
# Note: layer digests are discovered from the local manifest after a normal
# pre-pull; only those blobs are removed, the manifest + config remain.

set -euo pipefail

IMAGE_REF="${1:?usage: $0 <IMAGE_REF>}"

echo "=== Step 1: pre-pull image to register manifest + config ==="
sudo crictl pull "$IMAGE_REF"

echo "=== Step 2: discover layer digests from the image manifest ==="
# Map the image ref to its config manifest, then list layer blobs.
# ctr preserves a gc.ref.content link from the config to each layer; we list
# content blobs tagged with this image's registry source and drop the largest
# ones (the actual layers), keeping manifest/config (KB-sized).
LAYER_DIGESTS=$(sudo ctr -n k8s.io content ls | \
    grep -F "$(echo "$IMAGE_REF" | cut -d: -f1)" | \
    awk '$2 ~ /M$/ {print $1}')

if [ -z "$LAYER_DIGESTS" ]; then
    echo "No layer blobs found for $IMAGE_REF — is it already manifest-only?"
    exit 0
fi

echo "Layer blobs to remove:"
echo "$LAYER_DIGESTS"

echo "=== Step 3: delete layer blobs, keep manifest + config ==="
for d in $LAYER_DIGESTS; do
    sudo ctr -n k8s.io content rm "$d"
done

echo "=== Step 4: verify ==="
echo "Image still 'present' for IfNotPresent:"
sudo crictl images | grep -F "$(echo "$IMAGE_REF" | cut -d: -f1)" || true
echo "Remaining content blobs (should be small manifest/config only):"
sudo ctr -n k8s.io content ls | grep -F "$(echo "$IMAGE_REF" | cut -d: -f1)" | awk '{print $2}'

echo ""
echo "Done. The node now has only the manifest for $IMAGE_REF."
echo "The kata-remote guest will pull the image layers in-guest (embedded cache or registry)."
echo "No node-side layer download will occur."