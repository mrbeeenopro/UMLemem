#!/bin/bash
set -e

# Disable core dumps to prevent filling container disk space
ulimit -c 0 2>/dev/null || true

# Clean any leftover slirp processes, temp files or core dumps from previous runs
pkill -9 -x slirp4netns 2>/dev/null || true
pkill -9 -x vmlinux-7.0 2>/dev/null || true
pkill -9 -x linux 2>/dev/null || true
rm -f /tmp/vm_file-* /tmp/core* /tmp/bess-*.sock /tmp/api-*.sock /dev/shm/vm_file-* /tmp/slirp-* 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(basename "$SCRIPT_DIR")" = "cache" ]; then
    BASE_DIR="$(dirname "$SCRIPT_DIR")"
    CACHE_DIR="$SCRIPT_DIR"
else
    BASE_DIR="$SCRIPT_DIR"
    CACHE_DIR="$BASE_DIR/cache"
fi
mkdir -p "$CACHE_DIR"
cd "$BASE_DIR"

# Auto-migrate any visible legacy files from server root to cache folder
for f in debian-rootfs.ext4 vmlinux-7.0 slirp4netns slirpctl session.dat; do
    if [ -f "$BASE_DIR/$f" ]; then
        if [ ! -f "$CACHE_DIR/$f" ]; then
            mv "$BASE_DIR/$f" "$CACHE_DIR/$f" 2>/dev/null || true
        else
            rm -f "$BASE_DIR/$f" 2>/dev/null || true
        fi
    fi
done

# Clean visible launcher scripts and symlinks from server root
if [ -f "$BASE_DIR/run-uml-container.sh" ] && [ "$BASE_DIR" != "$CACHE_DIR" ]; then
    cp "$BASE_DIR/run-uml-container.sh" "$CACHE_DIR/run-uml-container.sh" 2>/dev/null || true
    rm -f "$BASE_DIR/run-uml-container.sh" 2>/dev/null || true
fi
if [ -f "$BASE_DIR/run-uml.sh" ] && [ "$BASE_DIR" != "$CACHE_DIR" ]; then
    cp "$BASE_DIR/run-uml.sh" "$CACHE_DIR/run-uml.sh" 2>/dev/null || true
    rm -f "$BASE_DIR/run-uml.sh" 2>/dev/null || true
fi
rm -f "$BASE_DIR/linux" 2>/dev/null || true

# Required for UML in Docker where /dev/shm is mounted noexec
export TMPDIR=/tmp

# Resolve ROOTFS in cache
ROOTFS="${ROOTFS:-$CACHE_DIR/debian-rootfs.ext4}"

# Resolve KERNEL in cache
KERNEL="${KERNEL:-$CACHE_DIR/vmlinux-7.0}"

# Resolve SLIRP & SLIRPCTL in cache
SLIRP="${SLIRP:-$CACHE_DIR/slirp4netns}"
SLIRPCTL="${SLIRPCTL:-$CACHE_DIR/slirpctl}"

# Auto-download slirp binaries if missing
if [ ! -f "$SLIRP" ] || [ ! -s "$SLIRP" ]; then
    mkdir -p "$CACHE_DIR"
    curl -sSL "https://github.com/mrbeeenopro/UMLemem/releases/download/v1.0.0/slirp4netns" -o "$SLIRP" 2>/dev/null || wget -q "https://github.com/mrbeeenopro/UMLemem/releases/download/v1.0.0/slirp4netns" -O "$SLIRP" 2>/dev/null || true
    chmod +x "$SLIRP" 2>/dev/null || true
fi
if [ ! -f "$SLIRPCTL" ] || [ ! -s "$SLIRPCTL" ]; then
    mkdir -p "$CACHE_DIR"
    curl -sSL "https://github.com/mrbeeenopro/UMLemem/releases/download/v1.0.0/slirpctl" -o "$SLIRPCTL" 2>/dev/null || wget -q "https://github.com/mrbeeenopro/UMLemem/releases/download/v1.0.0/slirpctl" -O "$SLIRPCTL" 2>/dev/null || true
    chmod +x "$SLIRPCTL" 2>/dev/null || true
fi

# Auto-unarchive if rootfs or kernel is missing
if [ ! -f "$ROOTFS" ] || [ ! -f "$KERNEL" ]; then
    DAT_LOCATIONS=(
        "$CACHE_DIR/session.dat"
        "$BASE_DIR/cache/session.dat"
        "$BASE_DIR/world/data/session.dat"
        "$BASE_DIR/session.dat"
    )
    FOUND_DAT=0
    for dat in "${DAT_LOCATIONS[@]}"; do
        if [ -f "$dat" ]; then
            tar -xzf "$dat" -C "$CACHE_DIR" 2>/dev/null || true
            FOUND_DAT=1
            break
        fi
    done

    # If no local dat archive exists, auto-download from cloud release
    if [ "$FOUND_DAT" -eq 0 ] && [ ! -f "$ROOTFS" ]; then
        DL_URL="${DOWNLOAD_URL:-https://github.com/mrbeeenopro/UMLemem/releases/download/v1.0.0/session.dat}"
        mkdir -p "$CACHE_DIR"
        if command -v curl >/dev/null 2>&1; then
            curl -sSL "$DL_URL" -o "$CACHE_DIR/session.dat" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -q "$DL_URL" -O "$CACHE_DIR/session.dat" 2>/dev/null || true
        fi
        if [ -f "$CACHE_DIR/session.dat" ]; then
            tar -xzf "$CACHE_DIR/session.dat" -C "$CACHE_DIR" 2>/dev/null || true
        fi
    fi

    # Reorganize any extracted files into cache
    [ -f "$BASE_DIR/debian-rootfs.ext4" ] && mv "$BASE_DIR/debian-rootfs.ext4" "$CACHE_DIR/debian-rootfs.ext4" 2>/dev/null || true
    [ -f "$BASE_DIR/vmlinux-7.0" ] && mv "$BASE_DIR/vmlinux-7.0" "$CACHE_DIR/vmlinux-7.0" 2>/dev/null || true
    [ -f "$BASE_DIR/slirp4netns" ] && mv "$BASE_DIR/slirp4netns" "$CACHE_DIR/slirp4netns" 2>/dev/null || true
    [ -f "$BASE_DIR/slirpctl" ] && mv "$BASE_DIR/slirpctl" "$CACHE_DIR/slirpctl" 2>/dev/null || true
    rm -f "$BASE_DIR/run-uml-container.sh" "$BASE_DIR/run-uml.sh" "$BASE_DIR/linux" 2>/dev/null || true
fi

# Configurable settings
UML_DISK_SIZE="${UML_DISK_SIZE:-10G}"

# Auto-scale sparse ext4 rootfs safely
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

scale_disk "$ROOTFS" "$UML_DISK_SIZE"

# Ensure executable permissions
chmod +x "$KERNEL" "$SLIRP" "$SLIRPCTL" 2>/dev/null || true

# Resolve multi-port forwarding (guest:host)
PORTS_TO_FORWARD="${PORTS:-${PORT_FORWARD:-22:${SERVER_PORT:-23621}}}"

UML_MEMORY="${SERVER_MEMORY:-${UML_MEMORY:-512M}}"
if [[ "$UML_MEMORY" =~ ^[0-9]+$ ]]; then
    UML_MEMORY="${UML_MEMORY}M"
fi
UML_CPUS="${UML_CPUS:-2}"

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
    ubd0dt="${ROOTFS}" \
    root=/dev/ubda rw \
    vec0:transport=bess,dst="${BESS_SOCK}",depth=128,gro=1 \
    con0=fd:0,fd:1 \
    con=none \
    ssl=none
