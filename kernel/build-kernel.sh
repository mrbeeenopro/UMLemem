#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# UMLemem Kernel 7.0 (SMP, Docker, Custom CPU) Build Script
# Author: Mrbeenopro
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/cache}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

echo "=== [1/5] Checking Build Environment & Dependencies ==="
REQUIRED_PKGS=(build-essential bison flex libssl-dev libelf-dev bc)
MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing build dependencies: ${MISSING_PKGS[*]}"
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update && apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
    else
        sudo apt-get update && sudo apt-get install -y --no-install-recommends "${MISSING_PKGS[@]}"
    fi
fi

echo "=== [2/5] Preparing Kernel Source Tree ==="
BUILD_SRC="${KERNEL_SRC:-/tmp/kernel-src-build}"

if [ -d "${KERNEL_SRC:-}" ]; then
    echo "Using provided KERNEL_SRC directory: $KERNEL_SRC"
    BUILD_SRC="$KERNEL_SRC"
elif [ -d "/home/mrbeenopro/kernel-src" ]; then
    echo "Found existing local kernel source in /home/mrbeenopro/kernel-src"
    BUILD_SRC="/home/mrbeenopro/kernel-src"
else
    echo "Fetching Linux 7.0 kernel source..."
    mkdir -p "$BUILD_SRC"

    if [ -f "/usr/src/linux-source-7.0.0.tar.bz2" ]; then
        echo "Extracting /usr/src/linux-source-7.0.0.tar.bz2..."
        tar -I lbzip2 -xf /usr/src/linux-source-7.0.0.tar.bz2 -C "$BUILD_SRC" --strip-components=1
    else
        echo "Installing linux-source-7.0.0..."
        if ! apt-cache show linux-source-7.0.0 >/dev/null 2>&1; then
            echo "Enabling Ubuntu resolute repository for linux-source-7.0.0..."
            if [ "$(id -u)" -eq 0 ]; then
                echo "deb http://archive.ubuntu.com/ubuntu/ resolute main" > /etc/apt/sources.list.d/resolute.list
            else
                echo "deb http://archive.ubuntu.com/ubuntu/ resolute main" | sudo tee /etc/apt/sources.list.d/resolute.list
            fi
        fi
        if [ "$(id -u)" -eq 0 ]; then
            apt-get update && apt-get install -y --no-install-recommends binutils linux-source-7.0.0 lbzip2
        else
            sudo apt-get update && sudo apt-get install -y --no-install-recommends binutils linux-source-7.0.0 lbzip2
        fi
        tar -I lbzip2 -xf /usr/src/linux-source-7.0.0.tar.bz2 -C "$BUILD_SRC" --strip-components=1
    fi
fi

cd "$BUILD_SRC"

echo "=== [3/5] Applying UMLemem Custom Kernel Patches ==="
for patch_file in "$SCRIPT_DIR/patches"/*.patch; do
    if [ -f "$patch_file" ]; then
        echo "Applying patch: $(basename "$patch_file")"
        patch -p1 -N -r - < "$patch_file" || {
            echo "Patch already applied or partially matched (continuing)..."
        }
    fi
done

echo "=== [4/5] Configuring UML Kernel (ARCH=um, SMP, Docker) ==="
cp "$SCRIPT_DIR/config-7.0" .config
make ARCH=um olddefconfig

NPROC=$(nproc 2>/dev/null || echo 2)
echo "=== [5/5] Compiling Kernel Binary with ARCH=um (-j$NPROC) ==="
make ARCH=um -j"$NPROC" linux

if [ ! -f "linux" ]; then
    echo "ERROR: Kernel compilation failed - 'linux' binary not generated!"
    exit 1
fi

echo "Stripping and packaging vmlinux-7.0..."
strip -s -o "$OUTPUT_DIR/vmlinux-7.0" linux
chmod +x "$OUTPUT_DIR/vmlinux-7.0"

echo "Kernel successfully built at: $OUTPUT_DIR/vmlinux-7.0"
file "$OUTPUT_DIR/vmlinux-7.0"
ls -lh "$OUTPUT_DIR/vmlinux-7.0"
