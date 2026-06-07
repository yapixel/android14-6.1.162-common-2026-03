#!/usr/bin/env bash
set -euo pipefail

# GitHub-hosted compatible Pixel 8 / GKI build script.
# This script intentionally avoids self-hosted paths such as /mnt/Hawai and
# /mnt/ccache. Toolchain paths are expected from the workflow, but safe
# fallbacks are provided for local testing.

: "${GITHUB_WORKSPACE:=$(pwd)}"
: "${KSU_VARIANT:=enhance}"
: "${ENABLE_SUSFS:=true}"
: "${FORCE_CLEAN:=false}"
: "${DIRTY_BUILD:=false}"
: "${TUNING_PROFILE:=balanced}"
: "${LTO_MODE:=thin}"
: "${MAKE_JOBS_OVERRIDE:=auto}"
: "${GOVERNOR_MODE:=dynasched}"
: "${DIRTY_MODULE_ABI_BYPASS:=true}"

mkdir -p "${GITHUB_WORKSPACE}/logs"
LOG_FILE="${GITHUB_WORKSPACE}/logs/build-${KSU_VARIANT}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

summarize_build_failure() {
  if [ ! -f "$LOG_FILE" ]; then
    return 0
  fi

  echo "::group::Build failure summary (${KSU_VARIANT})"
  echo "Last 200 lines of $LOG_FILE"
  tail -n 200 "$LOG_FILE" || true
  echo
  echo "Matching error signatures"
  grep -nE 'error:|fatal error:|undefined reference|No rule to make target|FAILED:' "$LOG_FILE" | tail -n 80 || echo "No common error signature matched."
  echo "::endgroup::"
}

trap 'status=$?; if [ "$status" -ne 0 ]; then summarize_build_failure; fi; exit "$status"' EXIT

cd "${GITHUB_WORKSPACE}/kernel"

export ARCH=arm64

# Resolve clang/LLVM tools. The workflow normally exports CLANG_BIN to
# /usr/lib/llvm-XX/bin. For local testing, fall back to clang from PATH.
if [ -z "${CLANG_BIN:-}" ]; then
  if command -v clang >/dev/null 2>&1; then
    CLANG_BIN="$(dirname "$(command -v clang)")"
  else
    echo "::error::clang not found and CLANG_BIN is not set"
    exit 1
  fi
fi

resolve_tool() {
  local name="$1"
  if [ -x "${CLANG_BIN}/${name}" ]; then
    printf '%s/%s\n' "$CLANG_BIN" "$name"
  elif command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  else
    echo "::error::Required LLVM tool not found: $name" >&2
    exit 1
  fi
}

CCACHE_PREFIX=""
if command -v ccache >/dev/null 2>&1; then
  CCACHE_PREFIX="ccache "
fi

export PATH="${CLANG_BIN}:$PATH"
export CROSS_COMPILE="${ARM64_TOOLCHAIN:-aarch64-linux-gnu-}"
export CROSS_COMPILE_COMPAT="${ARM32_TOOLCHAIN:-arm-linux-gnueabihf-}"
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CC="${CCACHE_PREFIX}${CLANG_BIN}/clang"
export CXX="${CCACHE_PREFIX}${CLANG_BIN}/clang++"
export HOSTCC="${CCACHE_PREFIX}${CLANG_BIN}/clang"
export HOSTCXX="${CCACHE_PREFIX}${CLANG_BIN}/clang++"
export LD="$(resolve_tool ld.lld)"
export HOSTLD="$(resolve_tool ld.lld)"
export AR="$(resolve_tool llvm-ar)"
export HOSTAR="$(resolve_tool llvm-ar)"
export NM="$(resolve_tool llvm-nm)"
export OBJCOPY="$(resolve_tool llvm-objcopy)"
export OBJDUMP="$(resolve_tool llvm-objdump)"
export READELF="$(resolve_tool llvm-readelf)"
export STRIP="$(resolve_tool llvm-strip)"
export CLANG_TRIPLE="aarch64-linux-gnu-"

if [ "${MAKE_JOBS_OVERRIDE}" = "auto" ]; then
  MAKE_JOBS="${BUILD_JOBS:-$(nproc)}"
else
  MAKE_JOBS="${MAKE_JOBS_OVERRIDE}"
fi
case "$MAKE_JOBS" in
  ''|*[!0-9]*|0)
    echo "::error::Invalid MAKE_JOBS=$MAKE_JOBS"
    exit 1
    ;;
esac

export TMPDIR="${TMPDIR:-${RUNNER_TEMP:-$GITHUB_WORKSPACE/.tmp}/kernel-tmp}"
export TEMP="$TMPDIR"
export TMP="$TMPDIR"
mkdir -p "$TMPDIR" "$CCACHE_DIR"
export MAKEFLAGS="-j${MAKE_JOBS} -l${BUILD_LOAD:-$((MAKE_JOBS + 1))}"
START_TIME=$SECONDS

KSU_LOCALVERSION='CONFIG_LOCALVERSION="-deepongi"'

make_common_args=(
  ARCH=arm64 LLVM=1 LLVM_IAS=1
  CC="$CC" LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP"
  READELF="$READELF" STRIP="$STRIP" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX"
  HOSTLD="$HOSTLD" HOSTAR="$HOSTAR" CLANG_TRIPLE="$CLANG_TRIPLE"
  CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT"
  O=out
)

add_gki_defconfig_once() {
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    if ! grep -Fxq "$line" arch/arm64/configs/gki_defconfig; then
      echo "$line" >> arch/arm64/configs/gki_defconfig
    fi
  done
}

delete_config_from_file() {
  local file="$1"
  shift
  local sym
  for sym in "$@"; do
    sed -i \
      -e "/^CONFIG_${sym}=/d" \
      -e "/^# CONFIG_${sym} is not set/d" \
      "$file"
  done
}

config_enable() {
  ./scripts/config --file out/.config -e "$1"
}

config_disable() {
  ./scripts/config --file out/.config -d "$1"
}

config_set_val() {
  ./scripts/config --file out/.config --set-val "$1" "$2"
}

run_make_config() {
  make "${make_common_args[@]}" "$@"
}

case "${TUNING_PROFILE}" in
  balanced|performance|battery) ;;
  *) echo "::error::Invalid TUNING_PROFILE=${TUNING_PROFILE}"; exit 1 ;;
esac
case "${LTO_MODE}" in
  thin|full|none) ;;
  *) echo "::error::Invalid LTO_MODE=${LTO_MODE}"; exit 1 ;;
esac
case "${GOVERNOR_MODE}" in
  dynasched|stock_schedutil) ;;
  *) echo "::error::Invalid GOVERNOR_MODE=${GOVERNOR_MODE}"; exit 1 ;;
esac
case "${ENABLE_SUSFS}" in
  true|false) ;;
  *) echo "::error::Invalid ENABLE_SUSFS=${ENABLE_SUSFS}"; exit 1 ;;
esac

# Clean stale config lines before adding desired base options.
delete_config_from_file arch/arm64/configs/gki_defconfig \
  KSU KSU_SUSFS LOCALVERSION LOCALVERSION_AUTO \
  CPU_FREQ_DEFAULT_GOV_SCHEDUTIL CPU_FREQ_DEFAULT_GOV_DYNASCHED \
  CPU_FREQ_GOV_DYNASCHED

cat <<EOF_CFG | add_gki_defconfig_once
CONFIG_ARM64_CORTEX_X3=y
CONFIG_ARM64_CORTEX_A715=y
CONFIG_ARM64_CORTEX_A510=y
CONFIG_ARM64_VA_BITS=48
CONFIG_ARM64_PA_BITS=48
CONFIG_SCHED_MC=y
CONFIG_SCHED_CORE=y
CONFIG_ENERGY_MODEL=y
CONFIG_CPU_FREQ=y
CONFIG_THERMAL=y
CONFIG_CMA=y
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_TCP_CONG_WESTWOOD=y
CONFIG_TCP_CONG_HTCP=y
CONFIG_TCP_CONG_VEGAS=y
CONFIG_TCP_CONG_VENO=y
CONFIG_TCP_CONG_YEAH=y
CONFIG_TCP_CONG_ILLINOIS=y
CONFIG_TCP_CONG_DCTCP=y
CONFIG_TCP_CONG_CDG=y
CONFIG_DEFAULT_TCP_CONG="bbr"
CONFIG_NET_SCH_FQ=y
CONFIG_IP_SET=y
CONFIG_NET_SCH_CAKE=y
CONFIG_IOSCHED_BFQ=y
CONFIG_BFQ_GROUP_IOSCHED=y
CONFIG_MQ_IOSCHED_DEADLINE=y
CONFIG_MQ_IOSCHED_KYBER=y
CONFIG_DEFAULT_IOSCHED="bfq"
CONFIG_PM_DEVFREQ=y
CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y
CONFIG_DEVFREQ_GOV_PERFORMANCE=y
CONFIG_DEVFREQ_GOV_POWERSAVE=y
CONFIG_DEVFREQ_GOV_USERSPACE=y
CONFIG_MALI_MIDGARD=m
CONFIG_MALI_PLATFORM_NAME="tensor"
CONFIG_KSU_DEBUG=n
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_LOCALVERSION_AUTO=n
${KSU_LOCALVERSION}
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_KSU_LSM_SECURITY_HOOKS=y
CONFIG_KSU=y
EOF_CFG

if [ "${ENABLE_SUSFS}" = "true" ]; then
  printf '%s\n' 'CONFIG_KSU_SUSFS=y' | add_gki_defconfig_once
fi

rm -f out/.config
run_make_config gki_defconfig

PROFILE_FRAGMENT="out/pixel8-profile-${TUNING_PROFILE}.config"
: > "$PROFILE_FRAGMENT"

# Apply all final settings through scripts/config, then run olddefconfig and
# syncconfig. This avoids the stale .config vs auto.conf mismatch that happens
# when .config is edited after Kconfig sync.
case "${TUNING_PROFILE}" in
  performance)
    config_enable HZ_300 || true
    config_disable HZ_250 || true
    config_set_val HZ 300 || true
    config_enable UCLAMP_TASK || true
    config_enable LRU_GEN || true
    config_enable LRU_GEN_ENABLED || true
    cat > "$PROFILE_FRAGMENT" <<'EOF_PROFILE'
CONFIG_HZ_300=y
CONFIG_HZ=300
CONFIG_UCLAMP_TASK=y
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
EOF_PROFILE
    ;;
  battery)
    config_enable HZ_250 || true
    config_disable HZ_300 || true
    config_set_val HZ 250 || true
    config_enable CPU_IDLE || true
    cat > "$PROFILE_FRAGMENT" <<'EOF_PROFILE'
CONFIG_HZ_250=y
CONFIG_HZ=250
CONFIG_CPU_IDLE=y
EOF_PROFILE
    ;;
  balanced)
    config_enable HZ_300 || true
    config_disable HZ_250 || true
    config_set_val HZ 300 || true
    config_enable LRU_GEN || true
    config_enable LRU_GEN_ENABLED || true
    cat > "$PROFILE_FRAGMENT" <<'EOF_PROFILE'
CONFIG_HZ_300=y
CONFIG_HZ=300
CONFIG_LRU_GEN=y
CONFIG_LRU_GEN_ENABLED=y
EOF_PROFILE
    ;;
esac

case "${LTO_MODE}" in
  thin)
    config_enable LTO_CLANG_THIN || true
    config_disable LTO_CLANG_FULL || true
    config_disable LTO_NONE || true
    ;;
  full)
    config_disable LTO_CLANG_THIN || true
    config_enable LTO_CLANG_FULL || true
    config_disable LTO_NONE || true
    ;;
  none)
    config_enable LTO_NONE || true
    config_disable LTO_CLANG_THIN || true
    config_disable LTO_CLANG_FULL || true
    ;;
esac

# Android bpfloader needs /sys/kernel/btf/vmlinux for common BPF programs.
# Build runners install dwarves/pahole in the workflow.
config_enable DEBUG_INFO || true
config_enable DEBUG_INFO_BTF || true
config_disable DEBUG_INFO_REDUCED || true
config_enable DEBUG_INFO_COMPRESSED_NONE || true

if [ "${DIRTY_MODULE_ABI_BYPASS}" = "true" ]; then
  config_enable MODULE_FORCE_LOAD || true
else
  config_disable MODULE_FORCE_LOAD || true
fi

config_enable KSU || true
if [ "${ENABLE_SUSFS}" = "true" ]; then
  config_enable KSU_SUSFS || true
else
  config_disable KSU_SUSFS || true
fi

case "${GOVERNOR_MODE}" in
  dynasched)
    # Keep schedutil available as a fallback, but make dynasched default.
    config_enable CPU_FREQ_GOV_DYNASCHED || true
    config_enable CPU_FREQ_DEFAULT_GOV_DYNASCHED || true
    config_disable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL || true
    ;;
  stock_schedutil)
    config_enable CPU_FREQ_GOV_SCHEDUTIL || true
    config_enable CPU_FREQ_DEFAULT_GOV_SCHEDUTIL || true
    config_disable CPU_FREQ_DEFAULT_GOV_DYNASCHED || true
    ;;
esac

run_make_config olddefconfig
run_make_config syncconfig

if grep -q '^CONFIG_SECURITY_SELINUX=y$' out/.config; then
  # KernelSU includes SELinux objsec.h directly; build generated SELinux
  # headers first so flask.h exists before the full build.
  run_make_config security/selinux/
fi

# Validate critical configs in generated Kconfig output, not only .config.
echo "::group::Config Validation"
CONFIG_AUTO="out/include/config/auto.conf"
CONFIG_ERRORS=0
if [ ! -f "$CONFIG_AUTO" ]; then
  echo "::error::$CONFIG_AUTO missing after syncconfig"
  CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
fi
if ! grep -q '^CONFIG_KSU=y' "$CONFIG_AUTO" 2>/dev/null; then
  echo "::error::CONFIG_KSU=y is not active in auto.conf"
  CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
fi
if [ "${ENABLE_SUSFS}" = "true" ]; then
  if ! grep -q '^CONFIG_KSU_SUSFS=y' "$CONFIG_AUTO" 2>/dev/null; then
    echo "::error::CONFIG_KSU_SUSFS=y is not active in auto.conf"
    CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
  fi
else
  if grep -q '^CONFIG_KSU_SUSFS=y' "$CONFIG_AUTO" 2>/dev/null; then
    echo "::error::CONFIG_KSU_SUSFS=y is active even though ENABLE_SUSFS=false"
    CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
  fi
fi
if [ "${GOVERNOR_MODE}" = "dynasched" ]; then
  if ! grep -q '^CONFIG_CPU_FREQ_DEFAULT_GOV_DYNASCHED=y' "$CONFIG_AUTO" 2>/dev/null; then
    echo "::error::GOVERNOR_MODE=dynasched but CONFIG_CPU_FREQ_DEFAULT_GOV_DYNASCHED is not active"
    CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
  fi
elif [ "${GOVERNOR_MODE}" = "stock_schedutil" ]; then
  if ! grep -q '^CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL=y' "$CONFIG_AUTO" 2>/dev/null; then
    echo "::error::GOVERNOR_MODE=stock_schedutil but CONFIG_CPU_FREQ_DEFAULT_GOV_SCHEDUTIL is not active"
    CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
  fi
fi
if [ "$CONFIG_ERRORS" -gt 0 ]; then
  echo "::endgroup::"
  echo "::group::Current generated config excerpts"
  grep -E 'CONFIG_KSU|CONFIG_CPU_FREQ.*GOV|CONFIG_LTO|CONFIG_LRU_GEN|CONFIG_DEBUG_INFO_BTF' "$CONFIG_AUTO" out/.config 2>/dev/null || true
  echo "::endgroup::"
  exit 1
fi
if ! grep -q '^CONFIG_LRU_GEN=y' "$CONFIG_AUTO" 2>/dev/null && [ "${TUNING_PROFILE}" != "battery" ]; then
  echo "::warning::CONFIG_LRU_GEN=y was requested but is not active. Kernel tree may lack MGLRU support."
fi
echo "Config validation passed"
echo "::endgroup::"

if [ "${FORCE_CLEAN}" = "true" ] && [ "${DIRTY_BUILD}" != "true" ]; then
  make -j"$MAKE_JOBS" O=out clean
fi

make -j"$MAKE_JOBS" O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CC" LD="$LD" AR="$AR" NM="$NM" OBJCOPY="$OBJCOPY" OBJDUMP="$OBJDUMP" \
  READELF="$READELF" STRIP="$STRIP" HOSTCC="$HOSTCC" HOSTCXX="$HOSTCXX" \
  HOSTLD="$HOSTLD" HOSTAR="$HOSTAR" CLANG_TRIPLE="$CLANG_TRIPLE" \
  CROSS_COMPILE="$CROSS_COMPILE" CROSS_COMPILE_COMPAT="$CROSS_COMPILE_COMPAT" \
  HOSTCFLAGS="-Wno-incompatible-pointer-types-discards-qualifiers" \
  all

test -f out/arch/arm64/boot/Image

trap - EXIT

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "BUILD_TIME=$((SECONDS - START_TIME))s" >> "$GITHUB_ENV"
fi
if command -v ccache >/dev/null 2>&1; then
  ccache -s | grep -E "(Cacheable calls|Hits|Misses|Hit rate|cache size)" || true
fi
