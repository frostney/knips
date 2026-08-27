#!/usr/bin/env bash
#
# win64-cross.sh — compile and link knips for x86_64-win64, from any host.
#
# Builds tools/ci/Dockerfile.win64 (an FPC 3.2.2 cross compiler for
# x86_64-win64, bootstrapped from upstream sources inside the container) and
# runs tools/ci/win64-gate.sh against a copy of this checkout.
#
# The first build is slow — it compiles a compiler, a Windows RTL and the
# Windows package set — and is cached as a Docker layer afterwards.
#
# Usage:
#   tools/win64-cross.sh                       # gate: compile + link + PE check
#   tools/win64-cross.sh --platform linux/amd64  # x86_64 container, so Wine works
#   tools/win64-cross.sh -- bash               # poke around inside
#
# The working tree is mounted read-only and copied inside the container, so a
# Windows cross build can never leave PE objects in the host checkout.

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)

platform=""
image_tag="knips-win64-cross"
declare -a command=(bash tools/ci/win64-gate.sh)

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
      echo "win64-cross.sh: unknown argument: $1" >&2
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

echo "==> building $image_tag (first time: bootstraps an FPC cross compiler)"
docker build ${platform_args[@]+"${platform_args[@]}"} \
  -f "$root/tools/ci/Dockerfile.win64" \
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
    '"$(printf '%q ' "${command[@]}")"'
  '
