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
  echo "rustc=$(rustc -V | tr '\n' ' ')"
  echo "cbindgen=$(cbindgen --version)"
  echo "kmd_upstream_commit=$KMD_UPSTREAM_COMMIT"
  echo "entry_point_link_arg=/ENTRY:driver_entry"
  echo "link_args_begin"
  awk '/^\[target\.aarch64-pc-windows-msvc\]/{f=1} f{print} f&&/^\]/{exit}' .cargo/config.toml
  echo "link_args_end"
} > "$OUT/BUILD-ENV.txt"
cat "$OUT/BUILD-ENV.txt"

( cd "$OUT" && sha256sum virtio_wddm_rs.sys include/virtio_wddm_uapi.h BUILD-ENV.txt > SHA256SUMS.build.txt; cat SHA256SUMS.build.txt )

echo "== build finished: $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
