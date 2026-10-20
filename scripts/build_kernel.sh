#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="$(cd "${KERNEL_DIR:-$ROOT_DIR/kernel}" && pwd)"
OUT_DIR="${OUT_DIR:-$KERNEL_DIR/out}"
ARCH="${ARCH:-arm64}"
DEFCONFIG="${DEFCONFIG:-gki_defconfig}"
FRAGMENTS="${FRAGMENTS:-arch/arm64/configs/mgk_64_k515_defconfig arch/arm64/configs/vendor/xiaomi_mgk.config arch/arm64/configs/vendor/lineage_mgk.config arch/arm64/configs/vendor/zircon.config}"
# Repo-owned fragment applied after the device fragments (empty to disable)
EXTRA_CONFIG="${EXTRA_CONFIG-$ROOT_DIR/configs/gki_build.config}"
TARGETS="${TARGETS:-Image.lz4 Image.gz modules}"
JOBS="${JOBS:-$(nproc)}"
CONFIG_ONLY="${CONFIG_ONLY:-0}"
INSTALL_MODULES="${INSTALL_MODULES:-1}"
# none | thin | full | empty (keep whatever the defconfig selects)
LTO="${LTO:-}"
# 1 to apply patches/*.patch to the kernel source, 0 to build it untouched
APPLY_PATCHES="${APPLY_PATCHES:-1}"

mkdir -p "$OUT_DIR"

MAKE=(make O="$OUT_DIR" ARCH="$ARCH" LLVM=1 LLVM_IAS=1 CC=clang)
MAKE+=(WERROR="${WERROR:-0}")
# Vendor subdirectories hard-code -Werror; keep warnings visible but non-fatal.
MAKE+=(KCFLAGS="${KCFLAGS:--Wno-error}")
if [[ -n "${CROSS_COMPILE:-}" ]]; then
	MAKE+=(CROSS_COMPILE="$CROSS_COMPILE")
fi

cd "$KERNEL_DIR"

echo "==> Kernel tree : $KERNEL_DIR"
echo "==> Output dir  : $OUT_DIR"
echo "==> Defconfig   : $DEFCONFIG"
echo "==> Fragments   : ${FRAGMENTS:-<none>}"
echo "==> LTO mode    : ${LTO:-defconfig default}"

if [[ "$APPLY_PATCHES" == "1" && -d "$ROOT_DIR/patches" ]]; then
	shopt -s nullglob
	for patch_file in "$ROOT_DIR"/patches/*.patch; do
		if git apply --check "$patch_file" 2>/dev/null; then
			echo "==> Applying $(basename "$patch_file")"
			git apply "$patch_file"
		elif git apply --check --reverse "$patch_file" 2>/dev/null; then
			echo "==> $(basename "$patch_file") is already applied"
		else
			echo "!!! Cannot apply $(basename "$patch_file")" >&2
			exit 1
		fi
	done
	shopt -u nullglob
fi

echo "==> Generating base configuration"
"${MAKE[@]}" "$DEFCONFIG"

LTO_FRAGMENT=""
if [[ -n "$LTO" ]]; then
	LTO_FRAGMENT="$OUT_DIR/lto.config"
	case "$LTO" in
	none)
		cat > "$LTO_FRAGMENT" <<-'EOF'
			CONFIG_LTO_NONE=y
			# CONFIG_LTO_CLANG is not set
			# CONFIG_LTO_CLANG_THIN is not set
			# CONFIG_LTO_CLANG_FULL is not set
		EOF
		;;
	thin)
		cat > "$LTO_FRAGMENT" <<-'EOF'
			CONFIG_LTO=y
			CONFIG_LTO_CLANG=y
			CONFIG_LTO_CLANG_THIN=y
			# CONFIG_LTO_CLANG_FULL is not set
		EOF
		;;
	full)
		cat > "$LTO_FRAGMENT" <<-'EOF'
			CONFIG_LTO=y
			CONFIG_LTO_CLANG=y
			CONFIG_LTO_CLANG_FULL=y
			# CONFIG_LTO_CLANG_THIN is not set
		EOF
		;;
	*)
		echo "Unknown LTO mode '$LTO' (expected none, thin or full)" >&2
		exit 1
		;;
	esac
	# heredocs above are indented, strip the leading tabs
	sed -i 's/^[[:space:]]*//' "$LTO_FRAGMENT"
fi

if [[ -n "$FRAGMENTS" || -n "$LTO_FRAGMENT" || -n "$EXTRA_CONFIG" ]]; then
	echo "==> Merging configuration fragments"
	# shellcheck disable=SC2086
	scripts/kconfig/merge_config.sh -m -O "$OUT_DIR" "$OUT_DIR/.config" \
		$FRAGMENTS ${LTO_FRAGMENT:+"$LTO_FRAGMENT"} ${EXTRA_CONFIG:+"$EXTRA_CONFIG"}
fi

echo "==> Resolving configuration (olddefconfig)"
"${MAKE[@]}" olddefconfig

if [[ "$CONFIG_ONLY" == "1" ]]; then
	echo "==> CONFIG_ONLY=1, stopping before compilation"
	echo "==> Final configuration: $OUT_DIR/.config"
	exit 0
fi

echo "==> Building targets: $TARGETS"
# shellcheck disable=SC2086
"${MAKE[@]}" -j"$JOBS" $TARGETS

if [[ "$INSTALL_MODULES" == "1" ]]; then
	echo "==> Installing modules to $OUT_DIR/modules"
	"${MAKE[@]}" INSTALL_MOD_PATH="$OUT_DIR/modules" modules_install
fi

echo "==> Build finished"
