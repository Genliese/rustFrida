#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TARGET_TRIPLE="aarch64-linux-android"
ANDROID_API="33"

if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then
  NDK_HOME="${ANDROID_NDK_HOME}"
elif [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then
  NDK_HOME="${ANDROID_NDK_ROOT}"
else
  NDK_HOME="${HOME}/Android/Sdk/ndk/android-ndk-r25c"
fi

TOOLCHAIN="${NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64"
LINKER="${TOOLCHAIN}/bin/${TARGET_TRIPLE}${ANDROID_API}-clang"
AR="${TOOLCHAIN}/bin/llvm-ar"
SYSROOT="${TOOLCHAIN}/sysroot"
CLANG_BAREMETAL_LIB="${TOOLCHAIN}/lib64/clang/14.0.7/lib/baremetal"

if [[ ! -f "${LINKER}" ]]; then
  echo "[ERROR] Android NDK linker not found: ${LINKER}"
  echo "        Set ANDROID_NDK_HOME/ANDROID_NDK_ROOT or install NDK r25c to ${HOME}/Android/Sdk/ndk/android-ndk-r25c"
  exit 1
fi

if [[ ! -f "${AR}" ]]; then
  echo "[ERROR] llvm-ar not found: ${AR}"
  exit 1
fi

if [[ -f "${HOME}/.cargo/env" ]]; then
  # shellcheck source=/dev/null
  source "${HOME}/.cargo/env"
fi

if ! command -v cargo >/dev/null 2>&1; then
  echo "[ERROR] cargo not found in PATH. Install Rust first: https://rustup.rs"
  exit 1
fi

echo "[INFO] Ensuring Rust target ${TARGET_TRIPLE}"
rustup target add "${TARGET_TRIPLE}" >/dev/null

echo "[INFO] Ensuring nightly + rust-src for ldmonitor-ebpf build"
rustup toolchain install nightly --profile minimal >/dev/null
rustup component add rust-src --toolchain nightly-x86_64-unknown-linux-gnu >/dev/null

if ! command -v bpf-linker >/dev/null 2>&1; then
  echo "[INFO] Installing bpf-linker"
  cargo install bpf-linker
fi

if [[ ! -f "${ROOT_DIR}/quickjs-hook/quickjs-src/quickjs.c" || ! -f "${ROOT_DIR}/quickjs-hook/quickjs-src/quickjs.h" ]]; then
  echo "[INFO] Initializing QuickJS submodule"
  git -C "${ROOT_DIR}" submodule update --init --recursive quickjs-hook/quickjs-src
fi

if [[ ! -f "${ROOT_DIR}/loader/build/loader.bin" ]]; then
  echo "[INFO] Building loader shellcode"
  python3 "${ROOT_DIR}/loader/loader.py" --ndk="${NDK_HOME}"
fi

cd "${ROOT_DIR}"

echo "[INFO] Starting Android build"
echo "       NDK_HOME=${NDK_HOME}"
echo "       TARGET=${TARGET_TRIPLE}"

run_cargo() {
  env \
    CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${LINKER}" \
    CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="${AR}" \
    CC_aarch64_linux_android="${LINKER}" \
    CC_aarch64-linux-android="${LINKER}" \
    BINDGEN_EXTRA_CLANG_ARGS="--sysroot=${SYSROOT}" \
    CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-l clang_rt.builtins-aarch64 -L ${CLANG_BAREMETAL_LIB}" \
    cargo "$@"
}

if [[ "${1:-}" == "--workspace" ]]; then
  # rust_frida uses include_bytes!(../../target/.../libagent.so), so ensure
  # agent is built first when target directory was cleaned.
  echo "[INFO] Prebuilding agent for embedded libagent.so"
  run_cargo build -p agent

  echo "[INFO] Building full workspace"
  run_cargo build
else
  # Build in two steps to avoid parallel race after deleting target/
  # (rust_frida compile-time include_bytes requires libagent.so to exist).
  echo "[INFO] Step 1/2: building agent"
  run_cargo build -p agent

  echo "[INFO] Step 2/2: building rust_frida"
  run_cargo build -p rust_frida
fi

echo "[OK] Build finished"