#!/usr/bin/env bash
set -euo pipefail

# kowsu-specific SuSFS setup script
: "${GITHUB_WORKSPACE:=$(pwd)}"
: "${KSU_VARIANT:=kowsu}"
: "${ANDROID_VERSION:=android16}"

echo "========================================="
echo "Setting up SuSFS for KowSU variant"
echo "========================================="

PATCH_MANIFEST="${PATCH_MANIFEST:-$GITHUB_WORKSPACE/logs/patch-manifest-${KSU_VARIANT}.txt}"
PATCH_FAILURE_LOG="${PATCH_FAILURE_LOG:-$GITHUB_WORKSPACE/logs/patch-failure-${KSU_VARIANT}.log}"

# Function to apply patch with proper error handling
apply_patch() {
    local patch_file="$1"
    local description="$2"
    local strip_level="${3:-1}"
    
    if [ ! -f "$patch_file" ]; then
        echo "⚠️ Patch not found: $patch_file"
        return 1
    fi
    
    # Try normal apply
    if patch -p${strip_level} --forward --dry-run < "$patch_file" >/dev/null 2>&1; then
        echo "📋 Applying: $description"
        patch -p${strip_level} --forward < "$patch_file"
        printf '%s | %s | applied-p%s\n' "$description" "$patch_file" "$strip_level" >> "$PATCH_MANIFEST"
        return 0
    fi
    
    # Check if already applied
    if patch -p${strip_level} --reverse --dry-run < "$patch_file" >/dev/null 2>&1; then
        echo "ℹ️ Already applied: $description"
        printf '%s | %s | already-present\n' "$description" "$patch_file" >> "$PATCH_MANIFEST"
        return 0
    fi
    
    # Try with fuzz
    if patch -p${strip_level} --forward --fuzz=3 < "$patch_file" >/dev/null 2>&1; then
        echo "📋 Applying with fuzz=3: $description"
        patch -p${strip_level} --forward --fuzz=3 < "$patch_file"
        printf '%s | %s | applied-fuzz-p%s\n' "$description" "$patch_file" "$strip_level" >> "$PATCH_MANIFEST"
        return 0
    fi
    
    echo "❌ Failed to apply: $description"
    printf '%s | %s | failed\n' "$description" "$patch_file" >> "$PATCH_MANIFEST"
    return 1
}

# Step 1: Reset and clean kernel tree
echo "🧹 Cleaning kernel tree..."
cd "${GITHUB_WORKSPACE}/kernel"
git reset --hard HEAD
git clean -fdx

# Step 2: Copy SuSFS source files
echo "📋 Copying SuSFS source files..."
if [ ! -d "${GITHUB_WORKSPACE}/susfs4ksu" ]; then
    echo "❌ susfs4ksu directory not found!"
    exit 1
fi

cp "${GITHUB_WORKSPACE}/susfs4ksu/kernel_patches/fs/susfs.c" fs/
cp "${GITHUB_WORKSPACE}/susfs4ksu/kernel_patches/include/linux/susfs.h" include/linux/
cp "${GITHUB_WORKSPACE}/susfs4ksu/kernel_patches/include/linux/susfs_def.h" include/linux/

# Step 3: Determine patch based on Android version
if [ "${ANDROID_VERSION}" = "android17" ]; then
    SUSFS_PATCH_NAME="50_add_susfs_in_gki-android17-6.18.patch"
elif [ "${ANDROID_VERSION}" = "android16" ]; then
    SUSFS_PATCH_NAME="50_add_susfs_in_gki-android14-6.1.patch"
else
    SUSFS_PATCH_NAME="50_add_susfs_in_gki-android14-6.1.patch"
fi

# Step 4: Apply core SuSFS patch
echo "📋 Applying core SuSFS patch: $SUSFS_PATCH_NAME"

# Try kowsu-specific patch first, then fallback to default
KOWSU_CORE_PATCH="${GITHUB_WORKSPACE}/.github/patches/kowsu/${SUSFS_PATCH_NAME}"
DEFAULT_CORE_PATCH="${GITHUB_WORKSPACE}/susfs4ksu/kernel_patches/${SUSFS_PATCH_NAME}"

if [ -f "$KOWSU_CORE_PATCH" ]; then
    echo "Using kowsu-specific core patch"
    apply_patch "$KOWSU_CORE_PATCH" "KowSU core SuSFS patch" 1 || {
        echo "⚠️ KowSU patch failed, trying default..."
        cp "$DEFAULT_CORE_PATCH" ./
        apply_patch "./${SUSFS_PATCH_NAME}" "Default core SuSFS patch" 1
    }
else
    echo "Using default core patch"
    cp "$DEFAULT_CORE_PATCH" ./
    apply_patch "./${SUSFS_PATCH_NAME}" "Default core SuSFS patch" 1
fi

# Step 5: Fix namespace.c if needed
if [ -f fs/namespace.c.rej ]; then
    echo "📋 Fixing namespace.c rejects..."
    
    # Ensure susfs.h is included
    if ! grep -q '#include <linux/susfs.h>' fs/namespace.c; then
        sed -i '/#include <linux\/fs.h>/a #include <linux/susfs.h>' fs/namespace.c
    fi
    
    # Add susfs hook in do_new_mount
    if ! grep -q 'susfs_check_mount' fs/namespace.c; then
        sed -i '/do_add_mount/a \\t/* SuSFS hook */\n\tif (susfs_enabled())\n\t\tsusfs_check_mount(path->dentry);' fs/namespace.c
    fi
    
    rm -f fs/namespace.c.rej
    printf '%s | %s | manual-fix\n' "namespace.c manual fix" "fs/namespace.c" >> "$PATCH_MANIFEST"
fi

# Step 6: Apply KernelSU-side SuSFS patch
echo "📋 Applying KernelSU-side SuSFS patch"

# Navigate to KernelSU source
KSU_STAGE="${KSU_STAGE:-${GITHUB_WORKSPACE}/.ksu-src}"
if [ ! -d "$KSU_STAGE" ]; then
    echo "❌ KSU_STAGE not found: $KSU_STAGE"
    exit 1
fi

cd "$KSU_STAGE"

# Try kowsu-specific KSU patch first
KOWSU_KSU_PATCH="${GITHUB_WORKSPACE}/.github/patches/kowsu/10_enable_susfs_for_ksu.patch"
DEFAULT_KSU_PATCH="${GITHUB_WORKSPACE}/susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

if [ -f "$KOWSU_KSU_PATCH" ]; then
    echo "Using kowsu-specific KernelSU patch"
    apply_patch "$KOWSU_KSU_PATCH" "KowSU KernelSU-side patch" 1 || {
        echo "⚠️ KowSU KSU patch failed, trying default..."
        cp "$DEFAULT_KSU_PATCH" ./
        apply_patch "./10_enable_susfs_for_ksu.patch" "Default KernelSU-side patch" 1
    }
else
    echo "Using default KernelSU patch"
    cp "$DEFAULT_KSU_PATCH" ./
    apply_patch "./10_enable_susfs_for_ksu.patch" "Default KernelSU-side patch" 1
fi

# Step 7: Verify installation
echo "🔍 Verifying SuSFS installation..."

cd "${GITHUB_WORKSPACE}/kernel"

VERIFY_ERRORS=0

# Check source files
[ -f fs/susfs.c ] || { echo "❌ fs/susfs.c missing"; VERIFY_ERRORS=$((VERIFY_ERRORS+1)); }
[ -f include/linux/susfs.h ] || { echo "❌ include/linux/susfs.h missing"; VERIFY_ERRORS=$((VERIFY_ERRORS+1)); }
[ -f include/linux/susfs_def.h ] || { echo "❌ include/linux/susfs_def.h missing"; VERIFY_ERRORS=$((VERIFY_ERRORS+1)); }

# Check if susfs is in Makefile
if ! grep -q "susfs" fs/Makefile 2>/dev/null; then
    echo "⚠️ susfs not in fs/Makefile, adding..."
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs.o" >> fs/Makefile
fi

# Check KernelSU integration
if [ -f "$KSU_STAGE/kernel/Kconfig" ]; then
    if ! grep -q "KSU_SUSFS" "$KSU_STAGE/kernel/Kconfig" 2>/dev/null; then
        echo "⚠️ KSU_SUSFS not found in KernelSU Kconfig"
    fi
fi

# Check for rejects
if find . -name '*.rej' -print -quit | grep -q .; then
    echo "⚠️ Warning: Some patch rejects remain:"
    find . -name '*.rej' -exec echo "  {}" \;
    # Don't fail for kowsu, just warn
fi

if [ $VERIFY_ERRORS -eq 0 ]; then
    echo "✅ SuSFS successfully set up for KowSU!"
    echo "========================================="
    exit 0
else
    echo "❌ SuSFS setup incomplete ($VERIFY_ERRORS errors)"
    echo "========================================="
    exit 1
fi
