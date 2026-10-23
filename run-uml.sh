#!/usr/bin/env bash
# ==============================================================================
# User Mode Linux (UML) Launcher with Kernel 7.0 and Debian Distro
# Supports Multi-vCPU (SMP), Internet NAT, SSH (port 22 & 2222), and X11 Forwarding
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_BIN="${SCRIPT_DIR}/vmlinux-7.0"
ROOTFS_IMG="${SCRIPT_DIR}/debian-rootfs.ext4"
CPUS=2
MEM="512M"
EXTRA_ARGS=()
EXEC_CMD=""
SHARED_DIR=""
TAP_DEV="tap-uml"
ENABLE_NET=1

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [-- ADDITIONAL_KERNEL_ARGS]

Options:
  -c, --cpus <NUM>      Number of virtual CPUs (default: 2, SMP mode)
  -m, --mem <SIZE>      Memory size (e.g. 512M, 1G, 2G; default: 512M)
  -r, --rootfs <PATH>   Path to ext4 rootfs disk image (default: debian-rootfs.ext4)
  -k, --kernel <PATH>   Path to UML kernel binary (default: vmlinux-7.0)
  -s, --share <DIR>     Mount host directory inside UML at /mnt/host via hostfs
  -e, --exec <CMD>      Run command directly inside UML non-interactively and exit
  --no-net              Disable tap network bridge
  -h, --help            Show this help message

Network & SSH Details:
  Host Bridge IP:       192.168.120.1
  UML Guest IP:         192.168.120.2
  SSH Port:             22 (from host) or 2222 (forwarded on host)
  Default Password:     12345678 (root)
  X11 Forwarding:       Supported (ssh -X / ssh -Y)

Examples:
  # Launch interactive Debian UML system with 2 vCPUs:
  ./run-uml.sh

  # Launch with 4 vCPUs and 1GB RAM:
  ./run-uml.sh -c 4 -m 1G

  # Run a command non-interactively (e.g. check internet & CPUs):
  ./run-uml.sh -c 2 --exec "ping -c 2 debian.org && nproc"

  # SSH into the running UML instance from the host:
  ssh -X root@192.168.120.2

  # Or connect via port 2222:
  ssh -X -p 2222 root@localhost
EOF
    exit 0
}

setup_host_network() {
    if ! ip link show "${TAP_DEV}" &>/dev/null; then
        echo "[*] Initializing tap device ${TAP_DEV}..."
        ip tuntap add dev "${TAP_DEV}" mode tap 2>/dev/null || true
        ip addr add 192.168.120.1/24 dev "${TAP_DEV}" 2>/dev/null || true
        ip link set "${TAP_DEV}" up 2>/dev/null || true
    else
        ip link set "${TAP_DEV}" up 2>/dev/null || true
        if ! ip addr show "${TAP_DEV}" | grep -q "192.168.120.1"; then
            ip addr add 192.168.120.1/24 dev "${TAP_DEV}" 2>/dev/null || true
        fi
    fi

    # Enable routing, NAT, and localnet routing
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.all.route_localnet=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.default.route_localnet=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf.lo.route_localnet=1 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.conf."${TAP_DEV}".route_localnet=1 >/dev/null 2>&1 || true
    iptables -t nat -C POSTROUTING -s 192.168.120.0/24 ! -d 192.168.120.0/24 -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 192.168.120.0/24 ! -d 192.168.120.0/24 -j MASQUERADE 2>/dev/null || true
    iptables -C FORWARD -s 192.168.120.0/24 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -s 192.168.120.0/24 -j ACCEPT 2>/dev/null || true
    iptables -C FORWARD -d 192.168.120.0/24 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -d 192.168.120.0/24 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    
    # Port forward host port 2222 -> UML 192.168.120.2:22
    iptables -t nat -C PREROUTING -p tcp --dport 2222 -j DNAT --to-destination 192.168.120.2:22 2>/dev/null || \
        iptables -t nat -A PREROUTING -p tcp --dport 2222 -j DNAT --to-destination 192.168.120.2:22 2>/dev/null || true
    iptables -t nat -C OUTPUT -p tcp -o lo --dport 2222 -j DNAT --to-destination 192.168.120.2:22 2>/dev/null || \
        iptables -t nat -A OUTPUT -p tcp -o lo --dport 2222 -j DNAT --to-destination 192.168.120.2:22 2>/dev/null || true
    iptables -C FORWARD -p tcp -d 192.168.120.2 --dport 22 -j ACCEPT 2>/dev/null || \
        iptables -A FORWARD -p tcp -d 192.168.120.2 --dport 22 -j ACCEPT 2>/dev/null || true
    iptables -t nat -C POSTROUTING -o "${TAP_DEV}" -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -o "${TAP_DEV}" -j MASQUERADE 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--cpus)
            CPUS="$2"
            shift 2
            ;;
        -m|--mem)
            MEM="$2"
            shift 2
            ;;
        -r|--rootfs)
            ROOTFS_IMG="$(realpath "$2")"
            shift 2
            ;;
        -k|--kernel)
            KERNEL_BIN="$(realpath "$2")"
            shift 2
            ;;
        -s|--share)
            SHARED_DIR="$(realpath "$2")"
            shift 2
            ;;
        -e|--exec)
            EXEC_CMD="$2"
            shift 2
            ;;
        --no-net)
            ENABLE_NET=0
            shift
            ;;
        -h|--help)
            usage
            ;;
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use -h or --help for help." >&2
            exit 1
            ;;
    esac
done

if [[ ! -f "${KERNEL_BIN}" ]]; then
    echo "Error: Kernel binary not found at ${KERNEL_BIN}" >&2
    exit 1
fi

if [[ ! -f "${ROOTFS_IMG}" ]]; then
    echo "Error: Rootfs image not found at ${ROOTFS_IMG}" >&2
    exit 1
fi

if [[ "${ENABLE_NET}" -eq 1 ]]; then
    setup_host_network
fi

UML_ARGS=(
    "ubd0dt=${ROOTFS_IMG}"
    "root=/dev/ubda"
    "rw"
    "mem=${MEM}"
    "ncpus=${CPUS}"
    "seccomp=auto"
    "console=tty0"
)

if [[ "${ENABLE_NET}" -eq 1 ]]; then
    UML_ARGS+=("vec0:transport=tap,ifname=${TAP_DEV}")
fi

if [[ -n "${SHARED_DIR}" ]]; then
    UML_ARGS+=("hostfs=${SHARED_DIR}")
fi

if [[ -n "${EXEC_CMD}" ]]; then
    # Create temporary init script
    TMP_INIT=$(mktemp -t uml_init.XXXXXX)
    cat << EOF > "${TMP_INIT}"
#!/bin/bash
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devpts devpts /dev/pts 2>/dev/null || true
ip link set lo up 2>/dev/null || true
if ip link show vec0 &>/dev/null; then
    ip addr add 192.168.120.2/24 dev vec0 2>/dev/null || true
    ip link set vec0 up 2>/dev/null || true
    ip route add default via 192.168.120.1 2>/dev/null || true
fi
${EXEC_CMD}
EXIT_CODE=\$?
poweroff -f
exit \${EXIT_CODE}
EOF
    chmod +x "${TMP_INIT}"

    # Mount rootfs and put init inside
    MNT_DIR=$(mktemp -d -t uml_mnt.XXXXXX)
    mount -o loop "${ROOTFS_IMG}" "${MNT_DIR}"
    cp "${TMP_INIT}" "${MNT_DIR}/tmp_cmd.sh"
    umount "${MNT_DIR}"
    rm -rf "${MNT_DIR}" "${TMP_INIT}"

    UML_ARGS+=("init=/tmp_cmd.sh")
fi

if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
    UML_ARGS+=("${EXTRA_ARGS[@]}")
fi

echo "=========================================================="
echo " Starting User Mode Linux (Kernel 7.0, Debian Distro)"
echo " vCPUs: ${CPUS} | Memory: ${MEM} | Rootfs: $(basename "${ROOTFS_IMG}") (10GB)"
if [[ "${ENABLE_NET}" -eq 1 ]]; then
    echo " Network: 192.168.120.2 | SSH: port 22 or port 2222"
fi
echo "=========================================================="

if [[ -n "${EXEC_CMD}" ]]; then
    "${KERNEL_BIN}" "${UML_ARGS[@]}"
    EXIT_STATUS=$?
    MNT_DIR=$(mktemp -d -t uml_mnt.XXXXXX)
    mount -o loop "${ROOTFS_IMG}" "${MNT_DIR}" 2>/dev/null && {
        rm -f "${MNT_DIR}/tmp_cmd.sh"
        umount "${MNT_DIR}"
    } || true
    rm -rf "${MNT_DIR}"
    exit ${EXIT_STATUS}
else
    exec "${KERNEL_BIN}" "${UML_ARGS[@]}"
fi
