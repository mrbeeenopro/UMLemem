#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# UMLemem Distro (Debian 13 Trixie, Docker, X11 Forwarding) Build Script
# Author: Mrbeenopro
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_DIR="${1:-$REPO_ROOT/cache}"
SUITE="${SUITE:-trixie}"
DISK_SIZE_MB="${DISK_SIZE_MB:-2048}"
ROOT_PASS="${ROOT_PASS:-12345678}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian/}"

mkdir -p "$OUTPUT_DIR"
WORK_DIR="/tmp/uml-distro-build-$$"
mkdir -p "$WORK_DIR"
MNT="$WORK_DIR/mnt"
mkdir -p "$MNT"

cleanup() {
    echo "Cleaning up mount and temporary files..."
    if mountpoint -q "$MNT"; then
        umount -lf "$MNT" || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

echo "=== [1/6] Checking Prerequisites ==="
REQUIRED_TOOLS=(debootstrap e2fsprogs tar gzip curl)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "Installing missing build tools: ${MISSING_TOOLS[*]}"
    if [ "$(id -u)" -eq 0 ]; then
        apt-get update && apt-get install -y --no-install-recommends "${MISSING_TOOLS[@]}"
    else
        sudo apt-get update && sudo apt-get install -y --no-install-recommends "${MISSING_TOOLS[@]}"
    fi
fi

echo "=== [2/6] Creating Sparse Ext4 Rootfs Disk Image (${DISK_SIZE_MB}MB) ==="
ROOTFS_IMG="$WORK_DIR/debian-rootfs.ext4"
truncate -s "${DISK_SIZE_MB}M" "$ROOTFS_IMG"
mkfs.ext4 -F -L debian-rootfs "$ROOTFS_IMG"

echo "Mounting image to $MNT..."
mount -o loop "$ROOTFS_IMG" "$MNT"

echo "=== [3/6] Bootstrapping Debian $SUITE Base System ==="
debootstrap \
    --variant=minbase \
    --include=iproute2,systemd-sysv,locales,curl,nano,procps,net-tools,iputils-ping,ca-certificates,udev,openssh-server,xauth,x11-apps,iptables,ip6tables,docker.io,containerd \
    "$SUITE" "$MNT" "$DEBIAN_MIRROR"

echo "=== [4/6] Configuring UMLemem Debian Distro ==="

# 1. /etc/fstab with optimized mount options
cat << 'EOF' > "$MNT/etc/fstab"
# /etc/fstab: static file system information for UMLemem.
/dev/ubda       /               ext4    noatime,nodiratime,commit=60,errors=remount-ro 0       1
proc            /proc           proc    defaults          0       0
sysfs           /sys            sysfs   defaults          0       0
devpts          /dev/pts        devpts  gid=5,mode=620    0       0
tmpfs           /dev/shm        tmpfs   defaults          0       0
EOF

# 2. Hostname and Hosts
echo "UMLemem" > "$MNT/etc/hostname"
cat << 'EOF' > "$MNT/etc/hosts"
127.0.0.1   localhost
127.0.1.1   UMLemem
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# 3. APT Sources for Debian Trixie
cat << EOF > "$MNT/etc/apt/sources.list"
deb $DEBIAN_MIRROR $SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR $SUITE-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main contrib non-free non-free-firmware
EOF

# 4. Networking: Loopback and eth0 DHCP
mkdir -p "$MNT/etc/network"
cat << 'EOF' > "$MNT/etc/network/interfaces"
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

# 5. Root Password
chroot "$MNT" /bin/bash -c "echo 'root:$ROOT_PASS' | chpasswd"

# 6. Serial Getty Console for UML tty0
mkdir -p "$MNT/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service "$MNT/etc/systemd/system/getty.target.wants/serial-getty@tty0.service"

# 7. SSH Server Configuration (Root login, X11 Forwarding & Compression)
mkdir -p "$MNT/etc/ssh/sshd_config.d"
cat << 'EOF' > "$MNT/etc/ssh/sshd_config.d/uml.conf"
PermitRootLogin yes
PasswordAuthentication yes
X11Forwarding yes
X11UseLocalhost yes
Compression yes
ClientAliveInterval 30
ClientAliveCountMax 5
EOF

# 8. Docker Daemon Configuration (Asynchronous Local Log Driver, Live Restore, Overlay2)
mkdir -p "$MNT/etc/docker"
cat << 'EOF' > "$MNT/etc/docker/daemon.json"
{
  "log-driver": "local",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "iptables": true,
  "ip6tables": false,
  "storage-driver": "overlay2",
  "live-restore": true
}
EOF

# 9. Performance & Environment Optimizations
cat << 'EOF' > "$MNT/etc/profile.d/00-optimizations.sh"
# Disable accessibility bus polling loops to reduce idle CPU in SSH
export NO_AT_SPI=1
# Force LLVMpipe multi-threaded software 3D rasterization for X11
export LIBGL_ALWAYS_SOFTWARE=1
export LP_NUM_THREADS=$(nproc 2>/dev/null || echo 2)
EOF

# 10. Generate Locale
chroot "$MNT" /bin/bash -c "echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen" || true

# 11. Ensure root permissions and clean cache
chroot "$MNT" apt-get clean || true
rm -rf "$MNT/var/lib/apt/lists/*" "$MNT/tmp/*" "$MNT/var/tmp/*"

echo "=== [5/6] Finalizing and Unmounting Disk Image ==="
sync
umount "$MNT"

# Move rootfs image to output directory
mv "$ROOTFS_IMG" "$OUTPUT_DIR/debian-rootfs.ext4"
echo "Rootfs ext4 image created at: $OUTPUT_DIR/debian-rootfs.ext4"

echo "=== [6/6] Packaging session.dat Bundle ==="
VMLINUX_SRC=""
if [ -f "$OUTPUT_DIR/vmlinux-7.0" ]; then
    VMLINUX_SRC="$OUTPUT_DIR/vmlinux-7.0"
elif [ -f "$REPO_ROOT/cache/vmlinux-7.0" ]; then
    VMLINUX_SRC="$REPO_ROOT/cache/vmlinux-7.0"
fi

if [ -n "$VMLINUX_SRC" ] && [ -f "$VMLINUX_SRC" ]; then
    echo "Bundling debian-rootfs.ext4 and $(basename "$VMLINUX_SRC") into session.dat..."
    SESSION_TMP="/tmp/session-pack-$$"
    mkdir -p "$SESSION_TMP"
    cp "$OUTPUT_DIR/debian-rootfs.ext4" "$SESSION_TMP/debian-rootfs.ext4"
    cp "$VMLINUX_SRC" "$SESSION_TMP/vmlinux-7.0"
    
    # Include slirp network daemons if available
    for daemon in slirp4netns slirpctl; do
        if [ -f "$REPO_ROOT/cache/$daemon" ]; then
            cp "$REPO_ROOT/cache/$daemon" "$SESSION_TMP/$daemon"
        elif [ -f "$OUTPUT_DIR/$daemon" ]; then
            cp "$OUTPUT_DIR/$daemon" "$SESSION_TMP/$daemon"
        fi
    done

    tar -czf "$OUTPUT_DIR/session.dat" -C "$SESSION_TMP" .
    rm -rf "$SESSION_TMP"
    echo "session.dat created successfully at: $OUTPUT_DIR/session.dat"
    ls -lh "$OUTPUT_DIR/session.dat"
else
    echo "Warning: vmlinux-7.0 not found in $OUTPUT_DIR or cache/. session.dat bundle skipped."
fi

echo "✅ Debian $SUITE Distro Build Completed Successfully!"
ls -lh "$OUTPUT_DIR/debian-rootfs.ext4"
