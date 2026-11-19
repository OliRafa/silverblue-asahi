#!/bin/bash
# Build the silverblue-asahi bootc image. Run on a native aarch64 (Apple Silicon) host or an arm64
# CI runner; elsewhere podman runs it under qemu-user emulation (pass ENGINE_ARGS=--arch=arm64),
# which works but takes far longer.
#
#   ./images/build.sh                      # -> silverblue-asahi:$FEDORA
#   ENGINE=podman FEDORA=44 ./images/build.sh silverblue-asahi
set -euo pipefail

TARGET="${1:-silverblue-asahi}"
FEDORA="${FEDORA:-44}"
ENGINE="${ENGINE:-podman}"
read -ra engine_args <<<"${ENGINE_ARGS:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# podman bind-mounts $NOTIFY_SOCKET into every build step, which leaves its mount point (say
# /run/user/1000/systemd/notify) in the image and fails bootc's nonempty-run-tmp lint. It is set
# when this runs under a systemd user service; CI builds through sudo, which drops it.
unset NOTIFY_SOCKET

case "$TARGET" in
  silverblue-asahi)
    TAG="${TAG:-silverblue-asahi:$FEDORA}"
    echo "==> $ENGINE build $TAG (Fedora Asahi Remix Silverblue $FEDORA)"
    exec "$ENGINE" build "${engine_args[@]}" \
      -f "$REPO_ROOT/images/silverblue-asahi/Containerfile" \
      --build-arg FEDORA="$FEDORA" \
      -t "$TAG" "$REPO_ROOT"
    ;;
  *)
    echo "usage: $0 [silverblue-asahi]" >&2
    exit 2
    ;;
esac
