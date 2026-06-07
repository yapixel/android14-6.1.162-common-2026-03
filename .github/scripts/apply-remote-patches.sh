#!/usr/bin/env bash
set -euo pipefail

: "${GITHUB_WORKSPACE:=$(pwd)}"
: "${KSU_VARIANT:=enhance}"
: "${KERNELTOAST_PATCH_POLICY:=best_effort}"
: "${GOVERNOR_MODE:=dynasched}"
: "${DIRTY_MODULE_ABI_BYPASS:=true}"
: "${PATCH_MANIFEST:=${GITHUB_WORKSPACE}/logs/patch-manifest-${KSU_VARIANT}.txt}"
: "${PATCH_FAILURE_LOG:=${GITHUB_WORKSPACE}/logs/patch-failure-${KSU_VARIANT}.log}"

mkdir -p "${GITHUB_WORKSPACE}/logs"
: > "$PATCH_FAILURE_LOG"
# Preserve SuSFS entries if setup-susfs.sh already wrote to the manifest.
[ -f "$PATCH_MANIFEST" ] || : > "$PATCH_MANIFEST"

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "PATCH_MANIFEST=$PATCH_MANIFEST" >> "$GITHUB_ENV"
  echo "PATCH_FAILURE_LOG=$PATCH_FAILURE_LOG" >> "$GITHUB_ENV"
fi

record_patch() {
  local desc="$1"
  local source="$2"
  local status="$3"
  printf '%s | %s | %s\n' "$desc" "$source" "$status" >> "$PATCH_MANIFEST"
}

log_patch_failure() {
  local patch_file="$1"
  local description="$2"
  local temp_log
  temp_log="$(mktemp)"
  patch -p1 --forward --dry-run < "$patch_file" >"$temp_log" 2>&1 || true
  {
    echo "=== ${description} ==="
    echo "Patch: $patch_file"
    cat "$temp_log"
    echo
  } >> "$PATCH_FAILURE_LOG"
  rm -f "$temp_log"
}

fetch_patch_or_fail() {
  local url="$1"
  local destination="$2"
  curl --fail --location --silent --show-error "$url" -o "$destination"
}

apply_patch_or_fail() {
  local patch_file="$1"
  local description="$2"

  if [ ! -s "$patch_file" ]; then
    echo "::error::Patch file missing or empty: $patch_file"
    record_patch "$description" "$patch_file" "missing"
    exit 1
  fi

  if patch -p1 --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
    patch -p1 --forward < "$patch_file"
    record_patch "$description" "$patch_file" "applied"
  elif patch -p1 --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
    echo "Already present: $description"
    record_patch "$description" "$patch_file" "already-present"
  elif patch -p1 --forward --fuzz=3 --dry-run < "$patch_file" >/dev/null 2>&1; then
    echo "Applying with fuzz=3: $description"
    patch -p1 --forward --fuzz=3 < "$patch_file"
    record_patch "$description" "$patch_file" "applied-fuzz"
  elif git apply --3way --check "$patch_file" >/dev/null 2>&1; then
    echo "Applying with git 3-way: $description"
    git apply --3way "$patch_file"
    record_patch "$description" "$patch_file" "applied-3way"
  else
    echo "::error::$description could not be applied cleanly: $patch_file"
    record_patch "$description" "$patch_file" "failed"
    log_patch_failure "$patch_file" "$description"
    echo "Patch failure log: $PATCH_FAILURE_LOG"
    exit 1
  fi
}

apply_repo_patch_or_fail() {
  local patch_file="$1"
  local description="$2"
  apply_patch_or_fail "${GITHUB_WORKSPACE}/${patch_file}" "$description"
}

apply_remote_patch_with_policy() {
  local url="$1"
  local local_name="$2"
  local description="$3"
  local destination="/tmp/${local_name}"

  if ! curl --fail --location --silent --show-error "$url" -o "$destination"; then
    if [ "$KERNELTOAST_PATCH_POLICY" = "strict" ]; then
      echo "::error::$description download failed in strict mode: $url"
      exit 1
    fi
    echo "Skipping $description: failed to download $url"
    record_patch "$description" "$url" "skipped-download-failed"
    return 0
  fi
  if [ ! -s "$destination" ]; then
    if [ "$KERNELTOAST_PATCH_POLICY" = "strict" ]; then
      echo "::error::$description downloaded empty patch in strict mode: $url"
      exit 1
    fi
    echo "Skipping $description: empty patch from $url"
    record_patch "$description" "$url" "skipped-empty"
    return 0
  fi

  if [ "$KERNELTOAST_PATCH_POLICY" = "strict" ]; then
    if git apply --check "$destination" >/dev/null 2>&1; then
      git apply "$destination"
      echo "Applied $description"
      record_patch "$description" "$url" "applied-strict"
      return 0
    fi
    if git apply --reverse --check "$destination" >/dev/null 2>&1; then
      echo "Already present: $description"
      record_patch "$description" "$url" "already-present-strict"
      return 0
    fi
    echo "::group::$description strict apply diagnostics"
    git apply --check --verbose "$destination" || true
    echo "::endgroup::"
    echo "::error::$description failed strict git apply check: $url"
    exit 1
  fi

  if patch -p1 --forward --dry-run < "$destination" >/dev/null 2>&1; then
    patch -p1 --forward < "$destination"
    echo "Applied $description"
    record_patch "$description" "$url" "applied"
  elif patch -p1 --reverse --dry-run < "$destination" >/dev/null 2>&1; then
    echo "Already present: $description"
    record_patch "$description" "$url" "already-present"
  elif git apply --3way --check "$destination" >/dev/null 2>&1; then
    echo "Applying with 3-way merge: $description"
    git apply --3way "$destination"
    record_patch "$description" "$url" "applied-3way"
  else
    echo "Skipping $description: patch drift against current kernel ref"
    record_patch "$description" "$url" "skipped-stale"
  fi
}

optional_python_patch() {
  local description="$1"
  local source="$2"
  shift 2

  if "$@"; then
    echo "Applied $description"
    record_patch "$description" "$source" "applied-adapted"
    return 0
  fi

  if [ "$KERNELTOAST_PATCH_POLICY" = "strict" ]; then
    echo "::error::$description failed in strict mode"
    record_patch "$description" "$source" "failed-strict"
    exit 1
  fi
  echo "Skipping $description: context drifted"
  record_patch "$description" "$source" "skipped-stale"
  return 0
}

apply_upstream_lts_patch_if_needed() {
  local target_sublevel="${UPSTREAM_LTS_PATCH_LEVEL:-}"
  local patch_url="${UPSTREAM_LTS_PATCH_URL:-}"
  local current_version current_patchlevel current_sublevel patch_file

  [ -n "$target_sublevel" ] || return 0
  [ -n "$patch_url" ] || return 0

  current_version=$(awk '/^VERSION =/ {print $3; exit}' Makefile)
  current_patchlevel=$(awk '/^PATCHLEVEL =/ {print $3; exit}' Makefile)
  current_sublevel=$(awk '/^SUBLEVEL =/ {print $3; exit}' Makefile)

  case "$target_sublevel:$current_sublevel" in
    *[!0-9:]*|:|*:)
      echo "::error::Invalid upstream LTS patch level state: target=${target_sublevel}, current=${current_sublevel}"
      exit 1
      ;;
  esac

  if [ "$current_version" != "6" ] || [ "$current_patchlevel" != "1" ]; then
    echo "Upstream 6.1.${target_sublevel} patch skipped: kernel is ${current_version}.${current_patchlevel}.${current_sublevel}"
    record_patch "upstream linux stable 6.1.${target_sublevel}" "$patch_url" "skipped-not-6.1"
    return 0
  fi

  if [ "$current_sublevel" -ge "$target_sublevel" ]; then
    echo "Kernel already at 6.1.${current_sublevel}; upstream 6.1.${target_sublevel} patch not needed."
    record_patch "upstream linux stable 6.1.${target_sublevel}" "$patch_url" "already-at-or-newer"
    return 0
  fi

  if [ $((target_sublevel - current_sublevel)) -ne 1 ]; then
    echo "::error::Refusing to apply single upstream 6.1.${target_sublevel} patch on top of 6.1.${current_sublevel}; expected 6.1.$((target_sublevel - 1))."
    exit 1
  fi

  command -v xz >/dev/null || { echo "::error::xz not found; cannot unpack ${patch_url}"; exit 1; }
  patch_file="/tmp/upstream-linux-6.1.${target_sublevel}.patch"
  curl --fail --location --silent --show-error "$patch_url" | xz -dc > "$patch_file"
  apply_patch_or_fail "$patch_file" "upstream Linux stable 6.1.${target_sublevel}"
  record_patch "upstream linux stable 6.1.${target_sublevel}" "$patch_url" "applied"
}

apply_kerneltoast_adapted_patches() {
  echo "Applying adapted kerneltoast scheduler/power commits (${KERNELTOAST_PATCH_POLICY})..."

  apply_remote_patch_with_policy "${KT_PATCH_ARCH_TOPOLOGY_MIN_FREQ_SCALE_URL}" \
    "kt-arch-topology-min-freq-scale.patch" \
    "kerneltoast: arch_topology minimum frequency scale"

  if [ -f kernel/sched/cass.c ]; then
    optional_python_patch "kerneltoast: sched/cass uclamp packing threshold" "kernel/sched/cass.c" python3 - <<'PY'
from pathlib import Path
path = Path('kernel/sched/cass.c')
text = path.read_text()
if 'arch_scale_min_freq_capacity(cpu)' in text:
    raise SystemExit(0)
old = '''\t\t\t/*
\t\t\t * A non-idle candidate may be better for energy
\t\t\t * efficiency when @p is uclamp boosted, or when the
\t\t\t * only idle candidate found so far is the prime CPU.
\t\t\t * Otherwise, prefer idle candidates.
\t\t\t */
\t\t\tif (!uc_min && !cass_prime_cpu(curr)) {
\t\t\t\t/* Discard any previous non-idle candidate */
\t\t\t\tif (!has_idle)
\t\t\t\t\tbest = curr;
\t\t\t\thas_idle = true;
\t\t\t}
'''
new = '''\t\t\t/*
\t\t\t * A non-idle candidate may be better for energy
\t\t\t * efficiency when @p is uclamp boosted above @curr's
\t\t\t * minimum capacity, or when the only idle candidate
\t\t\t * found so far is the prime CPU. Otherwise, prefer idle
\t\t\t * candidates.
\t\t\t */
\t\t\tif (!has_idle &&
\t\t\t    uc_min <= arch_scale_min_freq_capacity(cpu) &&
\t\t\t    !cass_prime_cpu(curr)) {
\t\t\t\t/* Discard any previous non-idle candidate */
\t\t\t\tbest = curr;
\t\t\t\thas_idle = true;
\t\t\t}
'''
if old not in text:
    raise SystemExit('kerneltoast CASS adaptation context not found')
path.write_text(text.replace(old, new, 1))
PY
  else
    echo "kerneltoast CASS adaptation not applicable; kernel/sched/cass.c absent."
    record_patch "kerneltoast: sched/cass uclamp packing threshold" "kernel/sched/cass.c" "not-applicable-no-cass"
  fi

  optional_python_patch "kerneltoast: schedutil ignore FIE rate-limit on scale-up" "kernel/sched/cpufreq_schedutil.c" python3 - <<'PY'
from pathlib import Path
path = Path('kernel/sched/cpufreq_schedutil.c')
text = path.read_text()
changed = False
if 'static bool sugov_should_rate_limit' not in text:
    old = '''static bool sugov_should_update_freq(struct sugov_policy *sg_policy, u64 time)
{
\ts64 delta_ns;

'''
    new = '''static bool sugov_should_rate_limit(struct sugov_policy *sg_policy, u64 time)
{
\ts64 delta_ns = time - sg_policy->last_freq_update_time;

\treturn delta_ns < sg_policy->freq_update_delay_ns;
}

static bool sugov_should_update_freq(struct sugov_policy *sg_policy, u64 time)
{
'''
    if old not in text:
        raise SystemExit('sugov_should_update_freq declaration context not found')
    text = text.replace(old, new, 1)
    old = '''\tdelta_ns = time - sg_policy->last_freq_update_time;

\treturn delta_ns >= sg_policy->freq_update_delay_ns;
}
'''
    new = '''\t/*
\t * With frequency-invariant utilization tracking, do not rate limit
\t * before computing the next frequency. The update path selectively
\t * rate limits only reductions once the next frequency is known.
\t */
\tif (arch_scale_freq_invariant())
\t\treturn true;

\t/* If the last frequency wasn't set yet then we can still amend it */
\tif (sg_policy->work_in_progress)
\t\treturn true;

\treturn !sugov_should_rate_limit(sg_policy, time);
}
'''
    if old not in text:
        raise SystemExit('sugov_should_update_freq rate-limit context not found')
    text = text.replace(old, new, 1)
    changed = True
if 'must_update:' not in text:
    old = '''\t\tif (sg_policy->next_freq == next_freq &&
\t\t    !cpufreq_driver_test_flags(CPUFREQ_NEED_UPDATE_LIMITS))
\t\t\treturn false;
\t} else if (sg_policy->next_freq == next_freq) {
\t\treturn false;
\t}

\tsg_policy->next_freq = next_freq;
'''
    new = '''\t\tif (cpufreq_driver_test_flags(CPUFREQ_NEED_UPDATE_LIMITS))
\t\t\tgoto must_update;
\t}

\t/*
\t * If frequency-invariant utilization bypassed the early rate-limit
\t * check, apply the delay only to frequency reductions now that the
\t * next frequency is known. Scaling up remains immediate.
\t */
\tif (next_freq == sg_policy->next_freq ||
\t    (next_freq < sg_policy->next_freq &&
\t     sugov_should_rate_limit(sg_policy, time)))
\t\treturn false;

must_update:
\tsg_policy->next_freq = next_freq;
'''
    if old not in text:
        raise SystemExit('sugov_update_next_freq context not found')
    text = text.replace(old, new, 1)
    changed = True
path.write_text(text)
PY

  optional_python_patch "kerneltoast: schedutil default rate-limit 2000us" "kernel/sched/cpufreq_schedutil.c" python3 - <<'PY'
from pathlib import Path
path = Path('kernel/sched/cpufreq_schedutil.c')
text = path.read_text()
old = 'tunables->rate_limit_us = cpufreq_policy_transition_delay_us(policy);'
new = 'tunables->rate_limit_us = 2000;'
if old in text:
    text = text.replace(old, new, 1)
path.write_text(text)
PY

  echo "Kerneltoast patchset processed (${KERNELTOAST_PATCH_POLICY})"
}

cd "${GITHUB_WORKSPACE}/kernel"

apply_upstream_lts_patch_if_needed

if [ "${KEEP_PROTECTED_EXPORTS:-false}" = "true" ]; then
  echo "Keeping android/abi_gki_protected_exports_* (KEEP_PROTECTED_EXPORTS=true)"
else
  echo "Removing GKI protected exports for Pixel 8 vendor module compatibility..."
  rm -f android/abi_gki_protected_exports_* || true
  record_patch "GKI protected exports removal" "android/abi_gki_protected_exports_*" "removed"
fi

apply_repo_patch_or_fail ".github/patches/fix-clidr-uninitialized.patch" "CLIDR initialization fix"

if [ "${APPLY_ONEPLUS12_WIFI_PATCH:-false}" = "true" ]; then
  echo "Applying OnePlus 12 (SM8650) Wi-Fi patch (opt-in)..."
  fetch_patch_or_fail "${WIFI_PATCH_URL}" /tmp/wifi-fix.patch
  apply_patch_or_fail /tmp/wifi-fix.patch "Wi-Fi fix"
else
  echo "OnePlus 12 (SM8650) Wi-Fi patch skipped: incompatible with Pixel 8 BCM4389"
  record_patch "OnePlus 12 Wi-Fi patch" "${WIFI_PATCH_URL:-unset}" "skipped-incompatible"
fi

if [ "${KERNELTOAST_PATCH_POLICY}" != "off" ]; then
  apply_kerneltoast_adapted_patches
else
  echo "kerneltoast patchset disabled by policy"
  record_patch "kerneltoast patchset" "policy" "disabled"
fi

if [ -f "drivers/kernelsu/app_profile.c" ] && grep -q "char comm\\[TASK_COMM_LEN\\];" drivers/kernelsu/app_profile.c; then
  python3 - <<'PY'
from pathlib import Path
p = Path('drivers/kernelsu/app_profile.c')
t = p.read_text()
p.write_text(t.replace('char comm[TASK_COMM_LEN];', 'static char comm[TASK_COMM_LEN];', 1))
PY
  echo "app_profile stack workaround applied"
  record_patch "app_profile stack workaround" "drivers/kernelsu/app_profile.c" "applied"
else
  echo "app_profile stack workaround not needed"
  record_patch "app_profile stack workaround" "drivers/kernelsu/app_profile.c" "not-needed"
fi

apply_repo_patch_or_fail ".github/patches/global/fix_setlocalversion_dirty.patch" "setlocalversion dirty suffix fix"

if [ "${DIRTY_MODULE_ABI_BYPASS}" = "true" ]; then
  echo "Applying dirty vendor module ABI bypass"
  apply_repo_patch_or_fail ".github/patches/global/dirty_allow_vendor_module_crcs.patch" "dirty vendor module CRC bypass"
  apply_repo_patch_or_fail ".github/patches/global/dirty_allow_vendor_module_vermagic.patch" "dirty vendor module vermagic bypass"
fi

apply_repo_patch_or_fail ".github/patches/global/fix_libbpf_strchr_cast.patch" "libbpf strchr cast fix"

if [ "${GOVERNOR_MODE}" = "dynasched" ]; then
  echo "Installing dynasched cluster-aware governor..."
  if [ ! -f "${GITHUB_WORKSPACE}/.github/patches/global/cpufreq_dynasched.c" ]; then
    echo "::error::Missing dynasched source: .github/patches/global/cpufreq_dynasched.c"
    exit 1
  fi
  cp "${GITHUB_WORKSPACE}/.github/patches/global/cpufreq_dynasched.c" kernel/sched/cpufreq_dynasched.c

  if patch -p1 --reverse --dry-run < "${GITHUB_WORKSPACE}/.github/patches/global/add_dynasched_governor.patch" >/dev/null 2>&1; then
    echo "dynasched governor patch already applied, skipping."
    record_patch "dynasched governor" "kernel/sched+drivers/cpufreq" "already-present"
  else
    apply_repo_patch_or_fail ".github/patches/global/add_dynasched_governor.patch" "dynasched governor"
  fi

  if ! grep -q '^CONFIG_CPU_FREQ_GOV_DYNASCHED=y$' arch/arm64/configs/gki_defconfig 2>/dev/null; then
    echo "CONFIG_CPU_FREQ_GOV_DYNASCHED=y" >> arch/arm64/configs/gki_defconfig
  fi

  python3 - <<'PY'
from pathlib import Path
path = Path('drivers/cpufreq/Kconfig')
text = path.read_text()
if 'CPU_FREQ_DEFAULT_GOV_DYNASCHED' not in text:
    text = text.replace(
        'default CPU_FREQ_DEFAULT_GOV_USERSPACE if ARM_SA1100_CPUFREQ || ARM_SA1110_CPUFREQ\n',
        'default CPU_FREQ_DEFAULT_GOV_USERSPACE if ARM_SA1100_CPUFREQ || ARM_SA1110_CPUFREQ\n\tdefault CPU_FREQ_DEFAULT_GOV_DYNASCHED if ARM64\n',
        1,
    )
    text = text.replace(
        'endchoice\n\nconfig CPU_FREQ_GOV_PERFORMANCE',
        'config CPU_FREQ_DEFAULT_GOV_DYNASCHED\n\tbool "dynasched"\n\tdepends on SMP\n\thelp\n\t  Use the dynasched Tensor G3 cluster-aware CPUFreq governor by default.\n\nendchoice\n\nconfig CPU_FREQ_GOV_PERFORMANCE',
        1,
    )
path.write_text(text)
PY
  sed -i '/^CONFIG_CPU_FREQ_DEFAULT_GOV_/d' arch/arm64/configs/gki_defconfig
  echo "CONFIG_CPU_FREQ_DEFAULT_GOV_DYNASCHED=y" >> arch/arm64/configs/gki_defconfig
  record_patch "dynasched governor source" "kernel/sched/cpufreq_dynasched.c" "applied"
else
  echo "dynasched governor disabled by governor_mode=${GOVERNOR_MODE}"
  record_patch "dynasched governor" "governor_mode=${GOVERNOR_MODE}" "disabled"
fi
