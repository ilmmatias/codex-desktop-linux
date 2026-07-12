#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_FILE="${1:-}"

[ -n "$PACKAGE_FILE" ] && [ -f "$PACKAGE_FILE" ] || {
    echo "Usage: $0 /path/to/package.gpkg.tar" >&2
    exit 2
}
command -v emerge >/dev/null 2>&1 || {
    echo "emerge is required to install a Gentoo binary package" >&2
    exit 1
}
command -v emaint >/dev/null 2>&1 || {
    echo "emaint is required to index the Gentoo binary package" >&2
    exit 1
}

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/app-misc"
cp "$PACKAGE_FILE" "$staging/app-misc/$(basename "$PACKAGE_FILE")"
PKGDIR="$staging" BINPKG_FORMAT=gpkg emaint binhost --fix >/dev/null
cpv="$(awk '/^CPV: app-misc\/codex-desktop-/ { print $2; exit }' "$staging/Packages")"
[ -n "$cpv" ] || {
    echo "The GPKG is not app-misc/codex-desktop or has invalid Portage metadata" >&2
    exit 1
}

if [ "${CODEX_GENTOO_INSTALL_DRY_RUN:-0}" = "1" ]; then
    printf 'PKGDIR=%q BINPKG_FORMAT=gpkg emerge --usepkgonly --oneshot =%q\n' "$staging" "$cpv"
    exit 0
fi

"$SCRIPT_DIR/sudo-with-alert.sh" env PKGDIR="$staging" BINPKG_FORMAT=gpkg \
    emerge --usepkgonly --oneshot "=$cpv"
