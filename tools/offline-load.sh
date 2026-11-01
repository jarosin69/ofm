#!/bin/sh
# OFM offline install bundle: check and load (step 2.8). Runs on the plant
# server (Linux), from the bundle folder made by tools/make-bundle.ps1:
#
#   sh offline-load.sh
#
# 1. Checks every file against SHA256SUMS (a damaged or altered copy stops here).
# 2. Loads every image into Docker (docker load); nothing is downloaded.
# 3. Checks that every image in images.txt is now present.
# Then continue with deploy/README.md, "Installing without internet".
set -eu
cd "$(dirname "$0")"

echo "== Checking the bundle"
sha256sum -c SHA256SUMS || { echo "Files missing or damaged: copy the bundle again." >&2; exit 1; }

echo "== Loading images into Docker (a few minutes)"
for f in images/*.tar.gz; do
  echo "loading  $f"
  docker load -i "$f" || { echo "docker load failed for $f. Is Docker running?" >&2; exit 1; }
done

missing=""
while IFS= read -r image; do
  [ -n "$image" ] || continue
  docker image inspect "$image" >/dev/null 2>&1 || missing="$missing $image"
done < images.txt
[ -z "$missing" ] || { echo "Not loaded:$missing" >&2; exit 1; }

echo "== All images loaded."
echo "Next: deploy/README.md, 'Installing without internet' (unpack ofm-repo.tar.gz, make-env.sh, docker compose up -d)."
