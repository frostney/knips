#!/usr/bin/env bash
#
# linux-ci.sh — run the platform-neutral suites on Linux, from any host.
#
# Builds tools/ci/Dockerfile.linux (Debian bookworm, FPC 3.2.2, the real
# lwpt 0.7.0 Linux binary) and runs tools/ci/linux-gate.sh inside it against
# a copy of this checkout: the neutral suites, a Linux `lwpt build`, a smoke
# of the resulting binary, and the formatter.
#
# Usage:
#   tools/linux-ci.sh                         # native container architecture
#   tools/linux-ci.sh --platform linux/amd64  # x86_64
#   tools/linux-ci.sh -- lwpt test            # any other command instead
#
# The working tree is mounted read-only and copied inside the container, so
# a Linux run can never leave Linux .ppu/.o files or an ELF build/knips in
# the host checkout.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)

platform=""
image_tag="knips-linux-ci"
declare -a command=(bash tools/ci/linux-gate.sh)

while [ $# -gt 0 ]; do
  case "$1" in
    --platform)
      platform="$2"
      shift 2
      ;;
    --platform=*)
      platform="${1#*=}"
      shift
      ;;
    --tag)
      image_tag="$2"
      shift 2
      ;;
    --)
      shift
      command=("$@")
      break
      ;;
    -h | --help)
      sed -n '2,20p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "linux-ci.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

declare -a platform_args=()
if [ -n "$platform" ]; then
  platform_args=(--platform "$platform")
  image_tag="$image_tag:$(echo "$platform" | tr '/' '-')"
else
  image_tag="$image_tag:native"
fi

echo "==> building $image_tag"
docker build ${platform_args[@]+"${platform_args[@]}"} \
  -f "$root/tools/ci/Dockerfile.linux" \
  -t "$image_tag" \
  "$root/tools/ci"

echo "==> running: ${command[*]}"
docker run --rm ${platform_args[@]+"${platform_args[@]}"} \
  -v "$root:/src:ro" \
  -w /work \
  "$image_tag" \
  bash -eu -o pipefail -c '
    tar -C /src --exclude=./.git --exclude=./build --exclude=./.lwpt/sessions -cf - . \
      | tar -C /work -xf -
    echo "--- toolchain ---"
    uname -m
    fpc -iV
    lwpt --version
    '"$(printf '%q ' "${command[@]}")"'
  '
