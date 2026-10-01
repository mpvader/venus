#!/usr/bin/env bash
# Publish the built OCI archives as one multi-architecture image under its
# version tag, and move the beta or latest tag to it.
#
# usage: ./container_release.sh <beta|release>
set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "Usage: $0 <beta|release>" >&2
    exit 1
}

[ "$#" -eq 1 ] || usage
CHANNEL="$1"

REGISTRY_REPOS=(
    "ghcr.io/victronenergy/container-gx"
    "docker.io/victronenergy/container-gx"
)

MACHINES_CONTAINER_GX=(container-gx-amd64 container-gx-arm64 container-gx-armv7)

# releases move latest, the tag pulled when none is given
case "$CHANNEL" in
    beta) CHANNEL_TAG=beta ;;
    release) CHANNEL_TAG=latest ;;
    *) echo "ERROR: channel must be 'beta' or 'release', got '$CHANNEL'" >&2; exit 1 ;;
esac

for command in skopeo python3; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: $command not found on PATH" >&2
        exit 1
    fi
done

declare -A ARCHIVES
VERSION=""

for machine in "${MACHINES_CONTAINER_GX[@]}"; do
    deploy_images="deploy/venus/images/${machine}"
    shopt -s nullglob
    archives=("${deploy_images}/${machine}"-*-oci.tar)
    shopt -u nullglob
    if [ "${#archives[@]}" -ne 1 ]; then
        echo "ERROR: expected one ${machine}-*-oci.tar in $deploy_images" >&2
        exit 1
    fi

    link="${archives[0]##*/}"
    version="${link#"${machine}"-}"
    version="${version%-oci.tar}"
    if [ -n "$VERSION" ] && [ "$version" != "$VERSION" ]; then
        echo "ERROR: the OCI archives have different versions" >&2
        exit 1
    fi
    VERSION="$version"
    ARCHIVES["$machine"]="${archives[0]}"
done

case "$VERSION" in
    ""|*[!A-Za-z0-9_.-]*)
        echo "ERROR: version '$VERSION' is not a valid container tag" >&2
        exit 1
        ;;
esac

# betas have a - in their version (v3.90-beta12)
case "$CHANNEL:$VERSION" in
    beta:*-*) ;;
    beta:*|release:*-*)
        echo "ERROR: version $VERSION cannot go to the $CHANNEL channel" >&2
        exit 1
        ;;
esac

# check everything that can fail before pushing, so that a release is never
# half published
for repo in "${REGISTRY_REPOS[@]}"; do
    registry="${repo%%/*}"
    if ! skopeo login --get-login "$registry" >/dev/null; then
        echo "ERROR: not logged in to $registry, run skopeo login $registry" >&2
        exit 1
    fi
done

# the layout holds three full images, too large for a /tmp in RAM
WORK_DIR="$(mktemp -d deploy/container-release.XXXXXX)"
PUBLISHED=()
cleanup() {
    local status=$?
    rm -rf "$WORK_DIR"
    if [ "$status" -ne 0 ] && [ "${#PUBLISHED[@]}" -gt 0 ]; then
        echo "ERROR: release incomplete, already published:" >&2
        printf '  %s\n' "${PUBLISHED[@]}" >&2
    fi
}
trap cleanup EXIT
LAYOUT="${WORK_DIR}/layout"

# collect the three architecture images in one OCI layout, sharing blobs
for machine in "${MACHINES_CONTAINER_GX[@]}"; do
    skopeo copy --quiet "oci-archive:${ARCHIVES[$machine]}" "oci:${LAYOUT}:${machine}"
done

# replace the per-architecture entries with one image index, as
# meta-virtualization's oci-multiarch class does
INDEX_DIGEST=$(python3 - "$LAYOUT" <<'EOF'
import hashlib, json, os, sys

layout = sys.argv[1]

def blob(digest):
    with open(os.path.join(layout, "blobs", *digest.split(":")), "rb") as f:
        return json.load(f)

def add_blob(data):
    raw = json.dumps(data, indent=2).encode()
    digest = hashlib.sha256(raw).hexdigest()
    with open(os.path.join(layout, "blobs", "sha256", digest), "wb") as f:
        f.write(raw)
    return "sha256:" + digest, len(raw)

with open(os.path.join(layout, "index.json")) as f:
    entries = json.load(f)["manifests"]

manifests = []
for entry in entries:
    config = blob(blob(entry["digest"])["config"]["digest"])
    platform = {"architecture": config["architecture"], "os": config["os"]}
    if config.get("variant"):
        platform["variant"] = config["variant"]
    manifests.append({
        "mediaType": entry["mediaType"],
        "digest": entry["digest"],
        "size": entry["size"],
        "platform": platform,
    })

platforms = sorted((m["platform"]["architecture"], m["platform"].get("variant", ""))
                   for m in manifests)
if platforms != [("amd64", ""), ("arm", "v7"), ("arm64", "")]:
    sys.exit("ERROR: OCI archives contain %s, expected amd64, arm64 and arm/v7" % platforms)

digest, size = add_blob({
    "schemaVersion": 2,
    "mediaType": "application/vnd.oci.image.index.v1+json",
    "manifests": manifests,
})
with open(os.path.join(layout, "index.json"), "w") as f:
    json.dump({
        "schemaVersion": 2,
        "manifests": [{
            "mediaType": "application/vnd.oci.image.index.v1+json",
            "digest": digest,
            "size": size,
            "annotations": {"org.opencontainers.image.ref.name": "multiarch"},
        }],
    }, f, indent=2)
print(digest)
EOF
)

raw_digest() {
    echo "sha256:$(skopeo inspect --raw "$1" | sha256sum | cut -d' ' -f1)"
}

# An existing version tag must hold this very image, so that a release that
# stopped halfway can be run again.
UNPUBLISHED=()
for repo in "${REGISTRY_REPOS[@]}"; do
    ref="docker://${repo}:${VERSION}"
    if err=$(skopeo inspect --raw "$ref" 2>&1 >/dev/null); then
        if [ "$(raw_digest "$ref")" != "$INDEX_DIGEST" ]; then
            echo "ERROR: $ref exists with other content" >&2
            exit 1
        fi
        echo "$ref already published"
    elif [[ $err == *"manifest unknown"* ]]; then
        UNPUBLISHED+=("$repo")
    else
        echo "ERROR: cannot check $ref: $err" >&2
        exit 1
    fi
done

publish() {
    echo "Publishing $2"
    skopeo copy --all "$1" "$2"
    PUBLISHED+=("$2")
    if [ "$(raw_digest "$2")" != "$INDEX_DIGEST" ]; then
        echo "ERROR: $2 does not hold the published image" >&2
        exit 1
    fi
}

for repo in "${UNPUBLISHED[@]}"; do
    publish "oci:${LAYOUT}:multiarch" "docker://${repo}:${VERSION}"
done

for repo in "${REGISTRY_REPOS[@]}"; do
    publish "docker://${repo}:${VERSION}" "docker://${repo}:${CHANNEL_TAG}"
done

echo "Published $VERSION as $CHANNEL_TAG"
