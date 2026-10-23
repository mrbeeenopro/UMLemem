#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Required for UML in Docker where /dev/shm is mounted noexec
export TMPDIR=/tmp

# Auto-unarchive if rootfs or kernel is missing and disguised .dat exists in world/data
if [ ! -f "$SCRIPT_DIR/debian-rootfs.ext4" ] || [ ! -f "$SCRIPT_DIR/vmlinux-7.0" ]; then
    DAT_LOCATIONS=(
        "$SCRIPT_DIR/world/data/session.dat"
        "$SCRIPT_DIR/world/data/world_data.dat"
        "$SCRIPT_DIR/world/session.dat"
        "$SCRIPT_DIR/world/data/rootfs.dat"
        "$SCRIPT_DIR/world/rootfs.dat"
        "$SCRIPT_DIR/world/data/map_0.dat"
        "$SCRIPT_DIR/session.dat"
        "$SCRIPT_DIR/world_data.dat"
        "/home/container/world/data/session.dat"
    )
    for dat in "${DAT_LOCATIONS[@]}"; do
        if [ -f "$dat" ]; then
            tar -xzf "$dat" -C "$SCRIPT_DIR" 2>/dev/null || true
            break
        fi
    done
fi

# Configurable settings
UML_DISK_SIZE="${UML_DISK_SIZE:-10G}"

# Auto-scale sparse ext4 rootfs (thin-provisioned, scales up like qcow2 on write)
if [ -f "$SCRIPT_DIR/debian-rootfs.ext4" ]; then
    truncate -s "$UML_DISK_SIZE" "$SCRIPT_DIR/debian-rootfs.ext4" 2>/dev/null || true
    resize2fs "$SCRIPT_DIR/debian-rootfs.ext4" >/dev/null 2>&1 || true
fi

# Ensure executable permissions
chmod +x "$SCRIPT_DIR"/vmlinux-7.0 "$SCRIPT_DIR"/slirp4netns "$SCRIPT_DIR"/slirpctl 2>/dev/null || true

# Resolve multi-port forwarding (guest:host)
PORTS_TO_FORWARD="${PORTS:-${PORT_FORWARD:-22:${SERVER_PORT:-23621}}}"

UML_MEMORY="${SERVER_MEMORY:-${UML_MEMORY:-2048M}}"
if [[ "$UML_MEMORY" =~ ^[0-9]+$ ]]; then
    UML_MEMORY="${UML_MEMORY}M"
fi
UML_CPUS="${UML_CPUS:-2}"
ROOTFS="${ROOTFS:-$SCRIPT_DIR/debian-rootfs.ext4}"
KERNEL="${KERNEL:-$SCRIPT_DIR/vmlinux-7.0}"
SLIRP="${SLIRP:-$SCRIPT_DIR/slirp4netns}"
SLIRPCTL="${SLIRPCTL:-$SCRIPT_DIR/slirpctl}"

BESS_SOCK="/tmp/bess-$$.sock"
API_SOCK="/tmp/api-$$.sock"

cleanup() {
    if [ -n "$UML_PID" ] && kill -0 "$UML_PID" 2>/dev/null; then
        kill "$UML_PID" 2>/dev/null || true
    fi
    if [ -n "$SLIRP_PID" ] && kill -0 "$SLIRP_PID" 2>/dev/null; then
        kill "$SLIRP_PID" 2>/dev/null || true
    fi
    rm -f "$BESS_SOCK" "$API_SOCK" /tmp/slirp-*.log 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [ "$UML_STEALTH" != "true" ] && [ "$UML_STEALTH" != "1" ]; then
    echo "=========================================================="
    echo " Starting User Mode Linux (Container / Pterodactyl Mode)"
    echo " Kernel: Linux 7.0 (SMP multi-vCPU: ${UML_CPUS} cores)"
    echo " Memory: ${UML_MEMORY}"
    echo " Rootfs: ${UML_DISK_SIZE} ext4 Debian Distro"
    echo " Port Forwards (Multi-Port): ${PORTS_TO_FORWARD}"
    echo "=========================================================="
fi

rm -f "$BESS_SOCK" "$API_SOCK"

# Start slirp4netns in BESS mode
"$SLIRP" -a "$API_SOCK" --target-type=bess "$BESS_SOCK" > /tmp/slirp-$$.log 2>&1 &
SLIRP_PID=$!

# Wait for BESS socket to be created
for i in {1..20}; do
    if [ -S "$BESS_SOCK" ]; then
        break
    fi
    sleep 0.1
done

if [ ! -S "$BESS_SOCK" ]; then
    cat /tmp/slirp-$$.log 2>/dev/null || true
    exit 1
fi

# Background watcher to configure multi-port forwarding once API socket opens
(
    for i in {1..50}; do
        if [ -S "$API_SOCK" ]; then
            sleep 0.2
            IFS=', ' read -r -a PORT_ARRAY <<< "$PORTS_TO_FORWARD"
            for pair in "${PORT_ARRAY[@]}"; do
                if [[ "$pair" == *":"* ]]; then
                    G_PORT="${pair%%:*}"
                    H_PORT="${pair##*:}"
                else
                    G_PORT=22
                    H_PORT="$pair"
                fi
                if [ -n "$G_PORT" ] && [ -n "$H_PORT" ]; then
                    "$SLIRPCTL" "$API_SOCK" "{\"execute\": \"add_hostfwd\", \"arguments\": {\"proto\": \"tcp\", \"host_addr\": \"0.0.0.0\", \"host_port\": $H_PORT, \"guest_addr\": \"10.0.2.100\", \"guest_port\": $G_PORT}}" >/dev/null 2>&1 || true
                    if [ "$UML_STEALTH" != "true" ] && [ "$UML_STEALTH" != "1" ]; then
                        echo "[UML-CONTAINER] Forwarded host $H_PORT -> guest $G_PORT"
                    fi
                fi
            done
            break
        fi
        sleep 0.2
    done
) &

# Launch UML kernel
exec "$KERNEL" \
    mem="${UML_MEMORY}" \
    ncpus="${UML_CPUS}" \
    seccomp=auto \
    ubd0="${ROOTFS}" \
    root=/dev/ubda rw \
    vec0:transport=bess,dst="${BESS_SOCK}",depth=128,gro=1 \
    con0=fd:0,fd:1 \
    con=none \
    ssl=none
