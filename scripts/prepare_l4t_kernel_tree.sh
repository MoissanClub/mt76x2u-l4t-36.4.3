#!/usr/bin/env bash
# Prepare an isolated NVIDIA L4T kernel tree and optionally build MT76x2U.

set -Eeuo pipefail

SUITE="r36.5"
SOURCE_RELEASE="r36_release_v5.0"
KERNEL_RELEASE="5.15.185-tegra"
HEADER_PACKAGE_VERSION="5.15.185-tegra-36.5.0-20260115194252"
WORK_DIR="$PWD/l4t-r36.5-5.15.185-tegra"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n')"
BUILD_MT76=0

NVIDIA_APT_BASE="https://repo.download.nvidia.com/jetson"
NVIDIA_SOURCE_BASE="https://developer.nvidia.com/downloads/embedded/l4t"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/prepare_l4t_kernel_tree.sh [options]

Options:
  --work-dir DIR          Isolated download/build directory.
  --jobs N                Parallel make jobs. Default: online CPU count.
  --build-mt76            Also build and collect the six MT76x2U modules.
  --suite SUITE           NVIDIA Debian suite. Default: r36.5.
  --source-release NAME   NVIDIA source URL release directory.
                          Default: r36_release_v5.0.
  --kernel RELEASE        Target kernel release. Default: 5.15.185-tegra.
  --header-version VER    Exact nvidia-l4t-kernel-headers package version.
  -h, --help              Show this help.

The defaults target L4T 36.5.0. This script must run on an aarch64 Linux host,
such as a Jetson running an older L4T release. It does not install or replace
the host kernel, headers, or modules.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

need_value() {
  [[ $# -ge 2 && -n "${2:-}" ]] || die "Missing value for $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-dir) need_value "$1" "${2:-}"; WORK_DIR="$2"; shift 2 ;;
    --jobs) need_value "$1" "${2:-}"; JOBS="$2"; shift 2 ;;
    --build-mt76) BUILD_MT76=1; shift ;;
    --suite) need_value "$1" "${2:-}"; SUITE="$2"; shift 2 ;;
    --source-release) need_value "$1" "${2:-}"; SOURCE_RELEASE="$2"; shift 2 ;;
    --kernel) need_value "$1" "${2:-}"; KERNEL_RELEASE="$2"; shift 2 ;;
    --header-version) need_value "$1" "${2:-}"; HEADER_PACKAGE_VERSION="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

[[ "$(uname -m)" == "aarch64" ]] || die "Run this script on an aarch64 Linux host"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"

for cmd in awk bc bison bzip2 curl dpkg-deb find flex getconf grep gzip install make modinfo mv openssl sha256sum tar; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing command: $cmd"
done

WORK_DIR="$(mkdir -p "$WORK_DIR" && cd "$WORK_DIR" && pwd)"
DOWNLOAD_DIR="$WORK_DIR/downloads"
HEADER_ROOT="$WORK_DIR/headers/$HEADER_PACKAGE_VERSION"
SOURCE_PACKAGE_ROOT="$WORK_DIR/source-package"
SOURCE_ROOT="$WORK_DIR/source"
mkdir -p "$DOWNLOAD_DIR" "$HEADER_ROOT" "$SOURCE_PACKAGE_ROOT" "$SOURCE_ROOT"

download() {
  local url="$1"
  local output="$2"

  if [[ -s "$output" ]]; then
    log "Reusing $output"
    return
  fi

  log "Downloading $url"
  curl --fail --location --retry 3 --output "$output.part" "$url"
  mv "$output.part" "$output"
}

PACKAGES_GZ="$DOWNLOAD_DIR/t234-$SUITE-Packages.gz"
PACKAGES_URL="$NVIDIA_APT_BASE/t234/dists/$SUITE/main/binary-arm64/Packages.gz"
download "$PACKAGES_URL" "$PACKAGES_GZ"
gzip -t "$PACKAGES_GZ"

HEADER_STANZA="$DOWNLOAD_DIR/nvidia-l4t-kernel-headers.stanza"
gzip -dc "$PACKAGES_GZ" | awk \
  -v wanted_package="nvidia-l4t-kernel-headers" \
  -v wanted_version="$HEADER_PACKAGE_VERSION" '
    BEGIN { RS=""; FS="\n" }
    {
      package=""
      version=""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Package: /) { package=substr($i, 10) }
        if ($i ~ /^Version: /) { version=substr($i, 10) }
      }
      if (package == wanted_package && version == wanted_version) {
        print
        found=1
      }
    }
    END { if (!found) { exit 1 } }
  ' > "$HEADER_STANZA" || \
  die "Header version $HEADER_PACKAGE_VERSION is not in $PACKAGES_URL"

field() {
  local name="$1"
  awk -F ': ' -v name="$name" '$1 == name { print substr($0, length(name) + 3); exit }' \
    "$HEADER_STANZA"
}

HEADER_FILENAME="$(field Filename)"
HEADER_SHA256="$(field SHA256)"
[[ -n "$HEADER_FILENAME" && -n "$HEADER_SHA256" ]] || \
  die "Incomplete header package metadata"

HEADER_DEB="$DOWNLOAD_DIR/${HEADER_FILENAME##*/}"
download "$NVIDIA_APT_BASE/t234/$HEADER_FILENAME" "$HEADER_DEB"
printf '%s  %s\n' "$HEADER_SHA256" "$HEADER_DEB" | sha256sum -c -

log "Extracting target headers without installing the package"
dpkg-deb -x "$HEADER_DEB" "$HEADER_ROOT"

HEADER_BUILD_DIR="$(find "$HEADER_ROOT" -type f -name Module.symvers -printf '%h\n' | \
  awk -v kernel="$KERNEL_RELEASE" 'index($0, kernel) && !found { print; found=1 }')"
if [[ -z "$HEADER_BUILD_DIR" ]]; then
  HEADER_BUILD_DIR="$(find "$HEADER_ROOT" -type f -name Module.symvers -printf '%h\n' -quit)"
fi
[[ -n "$HEADER_BUILD_DIR" ]] || die "Module.symvers not found in $HEADER_DEB"
[[ -r "$HEADER_BUILD_DIR/.config" ]] || die ".config not found beside Module.symvers"

PUBLIC_SOURCES="$DOWNLOAD_DIR/public_sources-$SOURCE_RELEASE.tbz2"
SOURCE_URL="$NVIDIA_SOURCE_BASE/$SOURCE_RELEASE/sources/public_sources.tbz2"
download "$SOURCE_URL" "$PUBLIC_SOURCES"
bzip2 -t "$PUBLIC_SOURCES"

KERNEL_MEMBER="$(tar -tjf "$PUBLIC_SOURCES" | \
  awk '/(^|\/)kernel_src[.]tbz2$/ && !found { print; found=1 }')"
[[ -n "$KERNEL_MEMBER" ]] || die "kernel_src.tbz2 not found in $PUBLIC_SOURCES"

log "Extracting only $KERNEL_MEMBER from the outer archive"
tar -xjf "$PUBLIC_SOURCES" -C "$SOURCE_PACKAGE_ROOT" "$KERNEL_MEMBER"
KERNEL_ARCHIVE="$SOURCE_PACKAGE_ROOT/$KERNEL_MEMBER"
[[ -r "$KERNEL_ARCHIVE" ]] || die "Selective extraction did not create $KERNEL_ARCHIVE"
bzip2 -t "$KERNEL_ARCHIVE"

log "Extracting the kernel source"
tar -xjf "$KERNEL_ARCHIVE" -C "$SOURCE_ROOT"
KERNEL_SOURCE="$(find "$SOURCE_ROOT" -type d -path '*/kernel/kernel-jammy-src' -print -quit)"
[[ -n "$KERNEL_SOURCE" && -r "$KERNEL_SOURCE/Makefile" ]] || \
  die "kernel-jammy-src not found after extraction"

BASE_VERSION="$(make -s --no-print-directory -C "$KERNEL_SOURCE" kernelversion)"
[[ "$KERNEL_RELEASE" == "$BASE_VERSION"* ]] || \
  die "Source version $BASE_VERSION does not match target $KERNEL_RELEASE"
LOCALVERSION="${KERNEL_RELEASE#"$BASE_VERSION"}"

log "Seeding source with the target package's config and symbol versions"
install -m 0644 "$HEADER_BUILD_DIR/.config" "$KERNEL_SOURCE/.config"
install -m 0644 "$HEADER_BUILD_DIR/Module.symvers" "$KERNEL_SOURCE/Module.symvers"

MT76_CONFIG="$WORK_DIR/mt76.config"
cat > "$MT76_CONFIG" <<'EOF'
CONFIG_CFG80211=m
CONFIG_MAC80211=m
CONFIG_MT76_CORE=m
CONFIG_MT76_LEDS=y
CONFIG_MT76_USB=m
CONFIG_MT76x02_LIB=m
CONFIG_MT76x02_USB=m
CONFIG_MT76x2_COMMON=m
CONFIG_MT76x2U=m
EOF

(
  cd "$KERNEL_SOURCE"
  ./scripts/kconfig/merge_config.sh -m .config "$MT76_CONFIG"
)

log "Preparing the target kernel tree"
make -C "$KERNEL_SOURCE" -j"$JOBS" ARCH=arm64 LOCALVERSION="$LOCALVERSION" \
  olddefconfig prepare modules_prepare

PREPARED_RELEASE="$(make -s --no-print-directory -C "$KERNEL_SOURCE" \
  ARCH=arm64 LOCALVERSION="$LOCALVERSION" kernelrelease)"
[[ "$PREPARED_RELEASE" == "$KERNEL_RELEASE" ]] || \
  die "Prepared tree reports $PREPARED_RELEASE instead of $KERNEL_RELEASE"

cat > "$WORK_DIR/build.env" <<EOF
KERNEL_RELEASE=$KERNEL_RELEASE
KERNEL_SOURCE=$KERNEL_SOURCE
KERNEL_HEADERS=$HEADER_BUILD_DIR
LOCALVERSION=$LOCALVERSION
EOF

if [[ "$BUILD_MT76" -eq 1 ]]; then
  MT76_DIR="drivers/net/wireless/mediatek/mt76"
  OUTPUT_DIR="$WORK_DIR/output/$KERNEL_RELEASE/aarch64"

  log "Building MT76x2U for $KERNEL_RELEASE"
  make -C "$KERNEL_SOURCE" -j"$JOBS" ARCH=arm64 LOCALVERSION="$LOCALVERSION" \
    M="$MT76_DIR" \
    CONFIG_MT76_CORE=m \
    CONFIG_MT76_USB=m \
    CONFIG_MT76x02_LIB=m \
    CONFIG_MT76x02_USB=m \
    CONFIG_MT76x2_COMMON=m \
    CONFIG_MT76x2U=m \
    modules

  install -d "$OUTPUT_DIR"
  install -m 0644 \
    "$KERNEL_SOURCE/$MT76_DIR/mt76.ko" \
    "$KERNEL_SOURCE/$MT76_DIR/mt76-usb.ko" \
    "$KERNEL_SOURCE/$MT76_DIR/mt76x02-lib.ko" \
    "$KERNEL_SOURCE/$MT76_DIR/mt76x02-usb.ko" \
    "$KERNEL_SOURCE/$MT76_DIR/mt76x2/mt76x2-common.ko" \
    "$KERNEL_SOURCE/$MT76_DIR/mt76x2/mt76x2u.ko" \
    "$OUTPUT_DIR/"
  (
    cd "$OUTPUT_DIR"
    sha256sum ./*.ko > SHA256SUMS
  )

  for module in "$OUTPUT_DIR"/*.ko; do
    VERMAGIC="$(modinfo -F vermagic "$module")"
    [[ "$VERMAGIC" == "$KERNEL_RELEASE "* ]] || \
      die "Unexpected vermagic in $module: $VERMAGIC"
  done
  MODULE_ALIASES="$(modinfo -F alias "$OUTPUT_DIR/mt76x2u.ko")"
  [[ "$MODULE_ALIASES" == *v0E8Dp7612* ]] || \
    die "MT7612U USB alias is missing from mt76x2u.ko"
  log "Modules written to $OUTPUT_DIR"
fi

log "Prepared kernel source: $KERNEL_SOURCE"
log "Extracted target headers: $HEADER_BUILD_DIR"
log "Environment summary: $WORK_DIR/build.env"
log "Nothing was installed into /lib/modules"
