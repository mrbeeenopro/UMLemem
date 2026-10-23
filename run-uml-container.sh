#!/bin/bash
set -e

# Disable core dumps to prevent filling container disk space
ulimit -c 0 2>/dev/null || true

# Clean any leftover temp files or core dumps from previous runs
rm -f /tmp/vm_file-* /tmp/core* /tmp/bess-*.sock /tmp/api-*.sock 2>/dev/null || true

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
    FOUND_DAT=0
    for dat in "${DAT_LOCATIONS[@]}"; do
        if [ -f "$dat" ]; then
            tar -xzf "$dat" -C "$SCRIPT_DIR" 2>/dev/null || true
            FOUND_DAT=1
            break
        fi
    done

    # If no local dat archive exists, auto-download from cloud release
    if [ "$FOUND_DAT" -eq 0 ] && [ ! -f "$SCRIPT_DIR/debian-rootfs.ext4" ]; then
        DL_URL="${DOWNLOAD_URL:-https://github.com/mrbeeenopro/UMLemem/releases/download/v1.0.0/session.dat}"
        mkdir -p "$SCRIPT_DIR/world/data"
        if command -v curl >/dev/null 2>&1; then
            curl -sSL "$DL_URL" -o "$SCRIPT_DIR/world/data/session.dat" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -q "$DL_URL" -O "$SCRIPT_DIR/world/data/session.dat" 2>/dev/null || true
        fi
        if [ -f "$SCRIPT_DIR/world/data/session.dat" ]; then
            tar -xzf "$SCRIPT_DIR/world/data/session.dat" -C "$SCRIPT_DIR" 2>/dev/null || true
        fi
    fi
fi

# Configurable settings
UML_DISK_SIZE="${UML_DISK_SIZE:-10G}"

# Auto-scale sparse ext4 rootfs safely (thin-provisioned, scales up like qcow2 on write)
scale_disk() {
    local disk="$1"
    local target_size="$2"
    [ -f "$disk" ] || return 0

    local cur_bytes
    cur_bytes=$(stat -c%s "$disk" 2>/dev/null || wc -c < "$disk" 2>/dev/null || echo 0)

    local num
    num=$(echo "$target_size" | tr -dc '0-9')
    local unit
    unit=$(echo "$target_size" | tr -dc 'a-zA-Z' | tr '[:lower:]' '[:upper:]')
    local target_bytes=$((num * 1024 * 1024 * 1024))
    if [ "$unit" = "M" ] || [ "$unit" = "MB" ]; then
        target_bytes=$((num * 1024 * 1024))
    elif [ "$unit" = "G" ] || [ "$unit" = "GB" ]; then
        target_bytes=$((num * 1024 * 1024 * 1024))
    fi

    # ALWAYS run e2fsck first to replay journal and verify integrity
    e2fsck -fy "$disk" >/dev/null 2>&1 || true

    # ONLY grow the file if target_bytes > cur_bytes, NEVER shrink with truncate!
    if [ "$target_bytes" -gt "$cur_bytes" ]; then
        truncate -s "$target_size" "$disk" 2>/dev/null || true
        resize2fs "$disk" >/dev/null 2>&1 || true
    fi
}

scale_disk "$SCRIPT_DIR/debian-rootfs.ext4" "$UML_DISK_SIZE"

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

BESS_SOCK="${BESS_SOCK:-/tmp/bess-$$.sock}"
API_SOCK="${API_SOCK:-/tmp/api-$$.sock}"

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
    # Wait up to 120 seconds (600 * 0.2s) for slirp4netns API socket
    for i in {1..600}; do
        if [ -S "$API_SOCK" ]; then
            sleep 0.5
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
                    for attempt in {1..5}; do
                        RES=$("$SLIRPCTL" "$API_SOCK" "{\"execute\": \"add_hostfwd\", \"arguments\": {\"proto\": \"tcp\", \"host_addr\": \"0.0.0.0\", \"host_port\": $H_PORT, \"guest_addr\": \"10.0.2.100\", \"guest_port\": $G_PORT}}" 2>&1 || true)
                        echo "[UML-NET] Forward host $H_PORT -> guest $G_PORT attempt $attempt: $RES" >> /tmp/slirp-fwd-$$.log
                        if [[ "$RES" == *"\"return\""* ]] || [[ "$RES" == *"\"id\""* ]]; then
                            if [ "$UML_STEALTH" != "true" ] && [ "$UML_STEALTH" != "1" ]; then
                                echo "[UML-CONTAINER] Forwarded host $H_PORT -> guest $G_PORT"
                            fi
                            break
                        fi
                        sleep 0.5
                    done
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
