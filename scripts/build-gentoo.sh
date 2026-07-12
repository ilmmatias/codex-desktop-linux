#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$REPO_DIR/scripts/lib/package-common.sh"

APP_DIR="${APP_DIR_OVERRIDE:-$REPO_DIR/codex-app}"
DIST_DIR="${DIST_DIR_OVERRIDE:-$REPO_DIR/dist}"
EBUILD_TEMPLATE="$REPO_DIR/packaging/linux/codex-desktop.ebuild.template"
DESKTOP_TEMPLATE="$REPO_DIR/packaging/linux/codex-desktop.desktop"
SERVICE_TEMPLATE="$REPO_DIR/packaging/linux/codex-update-manager.openrc"
USER_SERVICE_HELPER_SOURCE="$REPO_DIR/packaging/linux/codex-update-manager-openrc-user-service.sh"
PACKAGED_RUNTIME_SOURCE="$REPO_DIR/packaging/linux/codex-packaged-runtime-openrc.sh"
NO_UPDATER_CLEANUP_SOURCE="$REPO_DIR/packaging/linux/codex-no-updater-openrc-cleanup.sh"

PACKAGE_NAME="${PACKAGE_NAME:-codex-desktop}"
PACKAGE_CATEGORY="${PACKAGE_CATEGORY:-app-misc}"
PACKAGE_VERSION="${PACKAGE_VERSION:-$(date -u +%Y.%m.%d.%H%M%S)}"
PACKAGE_SERVICE_MANAGER="openrc-user"
ICON_SOURCE="$(resolve_package_icon_source)"
UPDATER_BINARY_SOURCE="${UPDATER_BINARY_SOURCE:-$REPO_DIR/target/release/codex-update-manager}"
UPDATER_SERVICE_SOURCE="${UPDATER_SERVICE_SOURCE:-$SERVICE_TEMPLATE}"

map_arch() {
    case "$(uname -m)" in
        x86_64) echo amd64 ;;
        aarch64) echo arm64 ;;
        *) error "Unsupported Gentoo architecture: $(uname -m)" ;;
    esac
}

gentoo_pvr() {
    local value="$PACKAGE_VERSION"
    if [[ "$value" =~ ^[0-9]+([.][0-9]+)*(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?$ ]]; then
        printf '%s\n' "$value"
        return
    fi

    local base="${value%%+*}"
    [[ "$base" =~ ^[0-9]+([.][0-9]+)*$ ]] || error \
        "PACKAGE_VERSION '$value' cannot be represented as a Gentoo package version"
    local revision
    revision="$(printf '%s' "$value" | cksum | awk '{print $1}')"
    printf '%s-r%s\n' "$base" "$revision"
}

write_repo_metadata() {
    local repo_root="$1"
    mkdir -p "$repo_root/metadata" "$repo_root/profiles"
    printf '%s\n' codex-local > "$repo_root/profiles/repo_name"
    printf '%s\n' "$PACKAGE_CATEGORY" > "$repo_root/profiles/categories"
    printf '%s\n' 'thin-manifests = true' > "$repo_root/metadata/layout.conf"
}

main() {
    ensure_app_layout
    ensure_file_exists "$EBUILD_TEMPLATE" "Gentoo ebuild template"
    ensure_file_exists "$ICON_SOURCE" "icon"
    ensure_file_exists "$PACKAGED_RUNTIME_SOURCE" "OpenRC packaged runtime helper"
    ensure_file_exists "$USER_SERVICE_HELPER_SOURCE" "OpenRC user service helper"
    if package_with_updater_enabled; then
        ensure_file_exists "$UPDATER_SERVICE_SOURCE" "OpenRC updater service"
    else
        info "Building package without codex-update-manager (PACKAGE_WITH_UPDATER=0)"
    fi
    command -v ebuild >/dev/null 2>&1 || error "ebuild is required (sys-apps/portage)"
    command -v tar >/dev/null 2>&1 || error "tar is required"
    ensure_updater_binary

    local arch pvr build_root repo_root package_dir staging_root ebuild_file
    arch="$(map_arch)"
    pvr="$(gentoo_pvr)"
    build_root="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$build_root'" EXIT
    repo_root="$build_root/repository"
    package_dir="$repo_root/$PACKAGE_CATEGORY/$PACKAGE_NAME"
    staging_root="$build_root/staging"
    ebuild_file="$package_dir/${PACKAGE_NAME}-${pvr}.ebuild"

    write_repo_metadata "$repo_root"
    mkdir -p "$package_dir/files" "$DIST_DIR" "$build_root/packages" \
        "$build_root/distfiles" "$build_root/portage-tmp"
    stage_common_package_files "$staging_root"
    stage_optional_update_builder_bundle "$staging_root"
    write_launcher_stub "$staging_root"
    printf '%s\n' "$PACKAGE_VERSION" > "$staging_root/opt/$PACKAGE_NAME/.codex-linux/package-version"
    run_linux_feature_package_hooks "$staging_root" "gentoo"
    normalize_package_payload_permissions "$staging_root"
    restore_linux_feature_payload_permissions "$staging_root"
    tar -C "$staging_root" -cf "$package_dir/files/payload.tar" .

    local updater_dependencies postinst_service prerm_service
    if package_with_updater_enabled; then
        updater_dependencies=$'    >=sys-apps/openrc-0.62\n    sys-auth/polkit'
        postinst_service=$'    local helper="${EROOT}opt/__PACKAGE_NAME__/.codex-linux/codex-update-manager-openrc-user-service.sh"\n    if [[ -r ${helper} ]]; then\n        source "${helper}"\n        if [[ -z ${REPLACING_VERSIONS} ]]; then\n            codex_ensure_user_service_running\n        else\n            codex_start_enabled_user_service\n        fi\n    fi'
        prerm_service=$'    if [[ -z ${REPLACED_BY_VERSION} ]]; then\n        local helper="${EROOT}opt/__PACKAGE_NAME__/.codex-linux/codex-update-manager-openrc-user-service.sh"\n        [[ -r ${helper} ]] && source "${helper}" && codex_cleanup_user_service disable-now\n    fi'
    else
        updater_dependencies=''
        postinst_service=$'    local cleanup="${EROOT}opt/__PACKAGE_NAME__/.codex-linux/codex-no-updater-transition-cleanup.sh"\n    [[ -r ${cleanup} ]] && source "${cleanup}" && codex_no_updater_transition_cleanup'
        prerm_service=''
    fi

    awk -v arch="$arch" -v package_name="$PACKAGE_NAME" \
        -v updater_dependencies="$updater_dependencies" \
        -v postinst_service="$postinst_service" -v prerm_service="$prerm_service" '
        { gsub(/__ARCH__/, arch); gsub(/__PACKAGE_NAME__/, package_name) }
        /__UPDATER_DEPENDENCIES__/ { print updater_dependencies; next }
        /__POSTINST_SERVICE__/ { print postinst_service; next }
        /__PRERM_SERVICE__/ { print prerm_service; next }
        { print }
    ' "$EBUILD_TEMPLATE" > "$ebuild_file"

    info "Building Portage GPKG for $PACKAGE_CATEGORY/$PACKAGE_NAME-$pvr"
    local repositories_config
    printf -v repositories_config '[codex-local]\nlocation = %s\n' "$repo_root"
    local -a portage_env=(
        "PORTAGE_REPOSITORIES=$repositories_config"
        "PORTAGE_TMPDIR=$build_root/portage-tmp"
        "PKGDIR=$build_root/packages"
        "DISTDIR=$build_root/distfiles"
        "BINPKG_FORMAT=gpkg"
    )
    if [ "$(id -u)" -ne 0 ]; then
        portage_env+=(
            "PORTAGE_USERNAME=${PORTAGE_USERNAME:-$(id -un)}"
            "PORTAGE_GRPNAME=${PORTAGE_GRPNAME:-$(id -gn)}"
        )
    fi
    env "${portage_env[@]}" \
        ebuild "$ebuild_file" manifest package >&2

    local package_file output_file
    package_file="$(find "$build_root/packages" -type f -name '*.gpkg.tar' -print -quit)"
    [ -f "$package_file" ] || error "Portage did not produce a .gpkg.tar package"
    # Portage derives identity from both metadata and the canonical PF filename;
    # adding an architecture suffix makes the GPKG invalid to its binhost indexer.
    output_file="$DIST_DIR/${PACKAGE_NAME}-${pvr}.gpkg.tar"
    cp "$package_file" "$output_file"
    ln -sfn "$(basename "$output_file")" "$DIST_DIR/${PACKAGE_NAME}-latest.gpkg.tar"
    info "Built package: $output_file"
    printf '%s\n' "$output_file"
}

main "$@"
