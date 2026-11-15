#!/bin/bash
# Generate the offline SwiftPM vendor tarball for hazkey-community.
#
# OBS workers have no network, so the SwiftPM dependencies pinned in
# hazkey-server/Package.resolved are resolved here and shipped as a second
# source archive.  The tarball contains a ready-made SwiftPM scratch directory
# (checkouts/ + workspace-state.json) that the spec unpacks to
# build/hazkey-server/swift-build, which is exactly the --scratch-path used by
# hazkey-server/build_swift.cmake.  With that state present,
# "swift package resolve" and "swift build" run fully offline.
#
# The vendor state MUST be generated with the same Swift version that OBS uses
# (swift-lang from devel:tools:compiler), otherwise SwiftPM may rewrite the
# workspace state and try to fetch.
#
# Usage: ./make-swiftpm-vendor.sh hazkey-community-<ver>.tar.zst [path-to-swift]
#   Run after "osc service manualrun" has produced the source tarball, and
#   re-run whenever Source0 or swift-lang changes.
set -euo pipefail

SWIFT_VERSION_REQUIRED=6.4.1
src_tar=$(realpath "${1:?usage: $0 hazkey-community-<ver>.tar.zst [swift]}")
SWIFT=${2:-swift}

cd "$(dirname "$0")"
version=$(basename "$src_tar")
version=${version#hazkey-community-}
version=${version%.tar.zst}

swift_version=$("$SWIFT" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -n1)
if [ "$swift_version" != "$SWIFT_VERSION_REQUIRED" ]; then
    echo "error: need Swift $SWIFT_VERSION_REQUIRED (OBS swift-lang), got '$swift_version'" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

tar -C "$work" -xf "$src_tar"
scratch="$work/swift-build"

HOME="$work/home" "$SWIFT" package resolve \
    --package-path "$work/hazkey-community-$version/hazkey-server" \
    --scratch-path "$scratch" \
    --force-resolved-versions

# Keep only what an offline build needs: the checkouts and the workspace state.
# .git directories are dropped (nothing reads them; the patch in
# build_swift.cmake is applied with "git apply", which works without a repo).
rm -rf "$scratch/repositories" "$scratch/artifacts" "$scratch/.buildSystem_debug"
find "$scratch/checkouts" -mindepth 2 -maxdepth 2 -name .git -exec rm -rf {} +
chmod -R u+w "$scratch"

out="hazkey-community-swiftpm-vendor-$version.tar.zst"
tar -C "$work" --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='2000-01-01 00:00Z' -cf - swift-build | zstd -19 -T0 -q -o "$out" -f
echo "wrote $out"
echo "  swift: $("$SWIFT" --version 2>&1 | head -n1)"
echo "  source: $(sha256sum "$src_tar" | cut -d' ' -f1)  $(basename "$src_tar")"
echo "  Package.resolved: $(tar -xOf "$src_tar" "hazkey-community-$version/hazkey-server/Package.resolved" | sha256sum | cut -d' ' -f1)"
