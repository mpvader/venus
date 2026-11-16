#!/usr/bin/env bash
# Convert a built OCI archive into an archive that every Docker image store
# can load.
#
# usage: ./container_loadable.sh <machine> [large]
set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "Usage: $0 <machine> [large]" >&2
    exit 1
}

[ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$2" = large ]; } || usage
MACHINE="$1"
# the image: container-gx or container-gx-large
IMAGE="container-gx${2:+-$2}"
# its files: container-gx-arm64-* or container-gx-large-arm64-*
NAME="${IMAGE}-${MACHINE#container-gx-}"

if ! command -v skopeo >/dev/null 2>&1; then
    echo "ERROR: skopeo not found on PATH" >&2
    exit 1
fi

DEPLOY_IMAGES="deploy/venus/images/${MACHINE}"
shopt -s nullglob
archives=("${DEPLOY_IMAGES}/${NAME}"-*-oci.tar)
shopt -u nullglob
if [ "${#archives[@]}" -ne 1 ]; then
    echo "ERROR: expected one ${NAME}-*-oci.tar in $DEPLOY_IMAGES" >&2
    exit 1
fi

link="${archives[0]##*/}"
version="${link#"${NAME}"-}"
version="${version%-oci.tar}"

# the link points to <name>-<datetime>-<version>-oci-<version>-...
archive="$(readlink "${archives[0]}")"
build="${archive%-oci-"${version}"-*}"
if [ "$build" = "$archive" ]; then
    echo "ERROR: cannot derive the build from $archive" >&2
    exit 1
fi

LOADABLE="${DEPLOY_IMAGES}/${build}-loadable.tar"
LOADABLE_LINK="${DEPLOY_IMAGES}/${NAME}-loadable.tar"

# bitbake removes the previous build's images, so remove its archive too
rm -f "${DEPLOY_IMAGES}/${NAME}"-*-loadable.tar
skopeo copy --quiet \
    "oci-archive:${DEPLOY_IMAGES}/${archive}" \
    "docker-archive:${LOADABLE}:${IMAGE}:${version}"
ln -sfn "${LOADABLE##*/}" "$LOADABLE_LINK"

echo "Created $LOADABLE"
