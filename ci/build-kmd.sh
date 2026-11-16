#!/usr/bin/env bash
# Build the stock (unpatched) ARM64 WDDM KMD with the NuGet-based WDK/SDK.
# Output: out/arm64/virtio_wddm_rs.sys (+ pdb, uapi header, build log).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
. ./versions.env

export RUSTUP_TOOLCHAIN=${RUSTUP_TOOLCHAIN:-$NIGHTLY}
TARGET=aarch64-pc-windows-msvc
ARCH=arm64
OUT=${OUT:-$ROOT/out/$ARCH}
WINSDK=${WINSDK:-$ROOT/winsdk}
LOG=$OUT/build.log
mkdir -p "$OUT/include"
exec > >(tee -a "$LOG") 2>&1

echo "== build started: $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
echo "repo_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
echo "repo_dirty=$(git status --porcelain 2>/dev/null | tr '\n' ' ' || true)"
rustc -vV
cargo -V
cbindgen --version
clang --version | head -1
clang-cl --version | head -1
command -v llvm-readobj >/dev/null && llvm-readobj --version | head -1 || true

echo "== ewdk.env =="
cp -f "$WINSDK/ewdk.env" "$ROOT/ewdk.env"
cat "$ROOT/ewdk.env"

echo "== committed cargo config (linker args for $TARGET) =="
cat .cargo/config.toml

PATCH_KIND=${PATCH:-none}
VARIANT=${KMD_VARIANT:-stock}
PATCH_LOG=$OUT/patch.log
case "$PATCH_KIND" in
  none)       PATCH_FILES=() ;;
  identity)   PATCH_FILES=(gpu-identity.patch) ;;
  identity-v2) PATCH_FILES=(gpu-identity-v2.patch) ;;
  cursor-hide) PATCH_FILES=(gpu-identity-v2.patch cursor-hide-zero.patch) ;;
  cursor-color) PATCH_FILES=(gpu-identity-v2.patch cursor-color.patch) ;;
  cursor-software) PATCH_FILES=(gpu-identity-v2.patch cursor-software.patch) ;;
  all)        PATCH_FILES=(gpu-identity-v2.patch cursor-hide-zero.patch kmd-attach-detach.patch) ;;
  gdi)        PATCH_FILES=(kmd-attach-detach.patch) ;;
  both)       PATCH_FILES=(gpu-identity.patch kmd-attach-detach.patch) ;;
  *) echo "ERROR: unknown PATCH=$PATCH_KIND (expected none|identity|identity-v2|cursor-hide|cursor-color|cursor-software|all|gdi|both)"; exit 2 ;;
esac
{
  echo "variant=$VARIANT patch=$PATCH_KIND"
  for pf in "${PATCH_FILES[@]}"; do
    case "$pf" in
      gpu-identity.patch)     EXPECTED=$IDENTITY_PATCH_SHA256 ;;
      gpu-identity-v2.patch)  EXPECTED=$IDENTITY_V2_PATCH_SHA256 ;;
      cursor-hide-zero.patch) EXPECTED=$CURSOR_HIDE_PATCH_SHA256 ;;
      cursor-color.patch) EXPECTED=$CURSOR_COLOR_PATCH_SHA256 ;;
      cursor-software.patch) EXPECTED=$CURSOR_SOFTWARE_PATCH_SHA256 ;;
      kmd-attach-detach.patch) EXPECTED=$GDI_PATCH_SHA256 ;;
      *) echo "ERROR: no pinned sha for $pf"; exit 1 ;;
    esac
    PATCH_FILE=$ROOT/patches/$pf
    ACTUAL_SHA=$(sha256sum "$PATCH_FILE" | awk '{print $1}')
    if [ "$ACTUAL_SHA" != "$EXPECTED" ]; then
      echo "ERROR: $PATCH_FILE sha256 $ACTUAL_SHA does not match pinned $EXPECTED"
      exit 1
    fi
    echo "patch_file=$pf sha256=$ACTUAL_SHA"
    git apply --check "$PATCH_FILE"
    git apply "$PATCH_FILE"
    echo "applied $pf"
  done
  git diff --stat
  git status --porcelain
} 2>&1 | tee "$PATCH_LOG"

echo "== cbindgen: virtio_wddm_uapi.h =="
cbindgen --config gpu-wddm/cbindgen.toml gpu-wddm/src/uapi.rs > "$OUT/include/virtio_wddm_uapi.h"

echo "== cargo build =="
cargo build --locked --package virtio-gpu-wddm-rs --target "$TARGET"

SYS=$OUT/virtio_wddm_rs.sys
cp "target/$TARGET/debug/virtio_gpu_wddm_rs.dll" "$SYS"
cp "target/$TARGET/debug/virtio_gpu_wddm_rs.pdb" "$OUT/" 2>/dev/null || true

echo "== PE checks =="
python3 ci/check-pe.py "$SYS"
if command -v llvm-readobj >/dev/null; then
  llvm-readobj --file-headers --coff-imports "$SYS"
else
  llvm-objdump -p "$SYS"
fi

{
  echo "build_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo_commit=$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "target=$TARGET"
  echo "profile=debug"
  echo "variant=$VARIANT"
  echo "patch=$PATCH_KIND"
  echo "patch_identity_sha256=$IDENTITY_PATCH_SHA256"
  echo "patch_identity_v2_sha256=$IDENTITY_V2_PATCH_SHA256"
  echo "patch_cursor_hide_sha256=$CURSOR_HIDE_PATCH_SHA256"
  echo "patch_cursor_color_sha256=$CURSOR_COLOR_PATCH_SHA256"
  echo "patch_cursor_software_sha256=$CURSOR_SOFTWARE_PATCH_SHA256"
  echo "patch_gdi_sha256=$GDI_PATCH_SHA256"
  echo "rustc=$(rustc -V | tr '\n' ' ')"
  echo "cbindgen=$(cbindgen --version)"
  echo "kmd_upstream_commit=$KMD_UPSTREAM_COMMIT"
  echo "entry_point_link_arg=/ENTRY:driver_entry"
  echo "link_args_begin"
  awk '/^\[target\.aarch64-pc-windows-msvc\]/{f=1} f{print} f&&/^\]/{exit}' .cargo/config.toml
  echo "link_args_end"
} > "$OUT/BUILD-ENV.txt"
cat "$OUT/BUILD-ENV.txt"

( cd "$OUT" && sha256sum virtio_wddm_rs.sys include/virtio_wddm_uapi.h BUILD-ENV.txt patch.log > SHA256SUMS.build.txt; cat SHA256SUMS.build.txt )

echo "== build finished: $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
