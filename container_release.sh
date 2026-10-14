#!/usr/bin/env bash
# Publish the OCI archives of a feed as one multi-architecture image under
# immutable version and channel tags. do_release.sh calls this with the
# archives it fetched from the candidate or release feed.
#
# usage: ./container_release.sh <beta|release> <dir with a directory per machine>
set -euo pipefail

cd "$(dirname "$0")"

usage() {
    echo "Usage: $0 <beta|release> <dir>" >&2
    exit 1
}

[ "$#" -eq 2 ] || usage
CHANNEL="$1"
SRC="$2"

REPOS=(
    "ghcr.io/victronenergy/container-gx"
    "docker.io/victronenergy/container-gx"
)

MACHINES=(container-amd64 container-arm64 container-armv7)

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

for machine in "${MACHINES[@]}"; do
    archive="${SRC}/${machine}/venus-${machine}.tar"
    if [ ! -f "$archive" ] || [ ! -f "${SRC}/${machine}/venus-container-version" ]; then
        echo "ERROR: no OCI archive or venus-container-version in ${SRC}/${machine}" >&2
        exit 1
    fi

    # ~ isn't allowed in a tag, see OCI_IMAGE_TAG in venus-image-container.bb
    version="$(sed -n 1p "${SRC}/${machine}/venus-container-version")"
    version="${version//\~/-}"
    if [ -n "$VERSION" ] && [ "$version" != "$VERSION" ]; then
        echo "ERROR: OCI archives do not have a common Venus version" >&2
        exit 1
    fi
    VERSION="$version"
    ARCHIVES["$machine"]="$archive"
done

case "$VERSION" in
    ""|*[!A-Za-z0-9_.-]*)
        echo "ERROR: version '$VERSION' is not a valid container tag" >&2
        exit 1
        ;;
esac

# betas have a - in their version; a release also goes to candidate, so
# beta can get a release version
case "$CHANNEL:$VERSION" in
    release:*-*)
        echo "ERROR: version $VERSION cannot go to the $CHANNEL channel" >&2
        exit 1
        ;;
esac

# check everything that can fail before pushing, so that a release is never
# half published
for repo in "${REPOS[@]}"; do
    registry="${repo%%/*}"
    if ! skopeo login --get-login "$registry" >/dev/null; then
        echo "ERROR: not logged in to $registry, run skopeo login $registry" >&2
        exit 1
    fi
done

# the layout holds three full images, too large for a /tmp in RAM
LAYOUT_DIR="$(mktemp -d deploy/container-release.XXXXXX)"
PUBLISHED=()
cleanup() {
    local status=$?
    rm -rf "$LAYOUT_DIR"
    if [ "$status" -ne 0 ] && [ "${#PUBLISHED[@]}" -gt 0 ]; then
        echo "ERROR: release incomplete, already published:" >&2
        printf '  %s\n' "${PUBLISHED[@]}" >&2
    fi
}
trap cleanup EXIT
LAYOUT="${LAYOUT_DIR}/layout"

# collect the three architecture images in one OCI layout, sharing blobs
for machine in "${MACHINES[@]}"; do
    skopeo copy --quiet "oci-archive:${ARCHIVES[$machine]}" "oci:${LAYOUT}:${machine}"
done

# replace the per-architecture entries with one image index, as
# meta-virtualization's oci-multiarch class does
INDEX=$(python3 - "$LAYOUT" <<'EOF'
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

# A release is published with its version tag when it goes to candidate;
# moving it to release then only moves latest. An existing version tag must
# hold this very image.
NEW_REPOS=()
for repo in "${REPOS[@]}"; do
    immutable="docker://${repo}:${VERSION}"
    if err=$(skopeo inspect --raw "$immutable" 2>&1 >/dev/null); then
        if [ "$(raw_digest "$immutable")" != "$INDEX" ]; then
            echo "ERROR: $immutable exists with other content" >&2
            exit 1
        fi
        echo "$immutable already published"
    elif [[ $err == *"manifest unknown"* ]]; then
        NEW_REPOS+=("$repo")
    else
        echo "ERROR: cannot check $immutable: $err" >&2
        exit 1
    fi
done

publish() {
    echo "Publishing $2"
    skopeo copy --all "$1" "$2"
    PUBLISHED+=("$2")
    if [ "$(raw_digest "$2")" != "$INDEX" ]; then
        echo "ERROR: $2 does not hold the published image" >&2
        exit 1
    fi
}

for repo in "${NEW_REPOS[@]}"; do
    publish "oci:${LAYOUT}:multiarch" "docker://${repo}:${VERSION}"
done

for repo in "${REPOS[@]}"; do
    publish "docker://${repo}:${VERSION}" "docker://${repo}:${CHANNEL_TAG}"
done

echo "Published $VERSION as $CHANNEL_TAG"
