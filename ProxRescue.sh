#!/bin/bash
set -euo pipefail

# When run via `bash -c "$(curl ...)"`, this whole script becomes the
# process's command line. Some procps tools (pgrep/pkill -f, used below)
# crash on such an oversized /proc/*/cmdline, so re-exec from a temp file
# to give the process a normal short command line.
if [ -n "${BASH_EXECUTION_STRING:-}" ]; then
    tmp_script=$(mktemp /tmp/proxrescue.XXXXXX.sh)
    # Prepend self-cleanup so the temp file is removed once the re-execed
    # script exits, regardless of how it terminates.
    {
        printf 'trap "rm -f %q" EXIT\n' "$tmp_script"
        printf '%s\n' "$BASH_EXECUTION_STRING"
    } >"$tmp_script"
    chmod +x "$tmp_script"
    exec bash "$tmp_script" "$@"
fi

# ============================================================================================
#  ██████  ██████   ██████  ██   ██ ███    ███  ██████  ██   ██    ██ ███    ██ ███████  ██████
# ██   ██ ██   ██ ██    ██  ██ ██  ████  ████ ██    ██  ██ ██     ██ ████   ██ ██      ██    ██
# ██████  ██████  ██    ██   ███   ██ ████ ██ ██    ██   ███      ██ ██ ██  ██ █████   ██    ██
# ██      ██   ██ ██    ██  ██ ██  ██  ██  ██ ██    ██  ██ ██     ██ ██  ██ ██ ██      ██    ██
# ██      ██   ██  ██████  ██   ██ ██      ██  ██████  ██   ██ ██ ██ ██   ████ ██       ██████
#
# Proxmox Products Installer in Rescue Mode for Hetzner
#
# © 2026 Proxmox UA www.proxmox.info. Все права защищены.
#
# Сообщества и поддержка:
# - Telegram:https://t.me/Proxmox_UA
# - GitHub: https://github.com/Proxmoxinfo/ProxMoxRescueHelper
# - Website: https://proxmox.info
#
# Этот скрипт предназначен для установки продуктов Proxmox в режиме восстановления на серверах Hetzner.
# ============================================================================================


VERSION_SCRIPT="1.0"
SCRIPT_TYPE="self-contained"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

QEMU_MONITOR_PORT=4444
QEMU_VNC_PORT=5900
QEMU_SSH_PORT=2222
QEMU_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
OVMF_PATH="/usr/share/ovmf/OVMF.fd"
REBOOT_TIMEOUT=5
NOVNC_VERSION=""
PROXMOX_MIRROR="https://download.proxmox.com"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh"

logo='
██████  ██████   ██████  ██   ██ ███    ███  ██████  ██   ██    ██ ███    ██ ███████  ██████  
██   ██ ██   ██ ██    ██  ██ ██  ████  ████ ██    ██  ██ ██     ██ ████   ██ ██      ██    ██ 
██████  ██████  ██    ██   ███   ██ ████ ██ ██    ██   ███      ██ ██ ██  ██ █████   ██    ██ 
██      ██   ██ ██    ██  ██ ██  ██  ██  ██ ██    ██  ██ ██     ██ ██  ██ ██ ██      ██    ██ 
██      ██   ██  ██████  ██   ██ ██      ██  ██████  ██   ██ ██ ██ ██   ████ ██       ██████  
'

VNC_PASSWORD=""
VNC_PASSWORD_LENGTH=10 
PRODUCT_CHOICE=""
NOVNC_PORT=""
USE_UEFI=""
NAME_SERVER=""
QEMU_MEMORY="3000"
QEMU_DISK_ARGS=()
CLI_FIX_SOURCES=""
CLI_NO_SUB=""
CLI_UPGRADE=""
CLI_DISABLE_HA=""
CLI_PRODUCT_CHOICE=""

if [ -z "$VNC_PASSWORD" ]; then
    if [ "$VNC_PASSWORD_LENGTH" -lt 8 ] || [ "$VNC_PASSWORD_LENGTH" -gt 20 ]; then
        echo "Warning: VNC_PASSWORD_LENGTH must be between 8 and 20. Using default (10)." >&2
        VNC_PASSWORD_LENGTH=10
    fi
    VNC_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c "$VNC_PASSWORD_LENGTH" || true)
fi
if [ -z "$NOVNC_PORT" ]; then
    NOVNC_PORT=8080
fi

validate_ipv4() {
    local ip="$1"
    local IFS='.'
    read -ra octets <<<"$ip"
    [ ${#octets[@]} -eq 4 ] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] && [ "$octet" -le 255 ] || return 1
    done
}

# BOOT_MODE_SOURCE: "auto" | "flag" — tracks how USE_UEFI was set
BOOT_MODE_SOURCE=""

# DNS_SOURCE: "auto" | "flag" — tracks how NAME_SERVER was set
DNS_SOURCE=""

detect_dns_server() {
    if [ -n "$NAME_SERVER" ]; then
        DNS_SOURCE="flag"
        echo "DNS server(s): $NAME_SERVER (forced via -dns flag)"
        return
    fi

    local resolv_file="/etc/resolv.conf"
    local first
    first=$(awk '/^nameserver[[:space:]]/{print $2; exit}' "$resolv_file" 2>/dev/null || true)

    # systemd-resolved stub resolver (127.0.0.53) — look up the real upstream DNS instead
    if [[ "$first" =~ ^127\. ]]; then
        resolv_file="/run/systemd/resolve/resolv.conf"
    fi

    local detected="" ns
    while read -r ns; do
        if validate_ipv4 "$ns" && [[ ! "$ns" =~ ^127\. ]]; then
            detected+="${detected:+ }$ns"
        fi
    done < <(awk '/^nameserver[[:space:]]/{print $2}' "$resolv_file" 2>/dev/null || true)

    if [ -n "$detected" ]; then
        NAME_SERVER="$detected"
        DNS_SOURCE="auto"
        echo "DNS server(s) auto-detected from rescue system: $NAME_SERVER"
    else
        NAME_SERVER="1.1.1.1"
        DNS_SOURCE="auto"
        echo "DNS server: could not detect from rescue system, using default $NAME_SERVER"
    fi
}

detect_boot_mode() {
    if [ -n "$USE_UEFI" ]; then
        BOOT_MODE_SOURCE="flag"
        echo "Boot mode: UEFI (forced via -uefi flag)"
        return
    fi
    if [ "$BOOT_MODE_SOURCE" = "flag" ]; then
        echo "Boot mode: Legacy BIOS (forced via -legacy flag)"
        return
    fi
    if [ -d /sys/firmware/efi ]; then
        USE_UEFI=true
        BOOT_MODE_SOURCE="auto"
        echo "Boot mode auto-detected: UEFI"
    else
        USE_UEFI=""
        BOOT_MODE_SOURCE="auto"
        echo "Boot mode auto-detected: Legacy BIOS"
    fi
}

show_help() {
    echo "$logo"
    echo "ProxRescue version $VERSION_SCRIPT"
    echo ""
    cat <<EOF
Usage: $0 [options]

Installation:
  -pve                       Install Proxmox Virtual Environment.
  -pbs                       Install Proxmox Backup Server.
  -pmg                       Install Proxmox Mail Gateway.
  -pdm                       Install Proxmox Datacenter Manager.

Post-install (applied automatically after installation):
  -fix-sources              Fix Debian base sources (deb.debian.org).
  -no-sub                   Switch Enterprise repos to no-subscription + remove nag.
  -upgrade                  Run apt update + dist-upgrade (requires -no-sub).
  -disable-ha               Disable HA services, single-node PVE only.
  -auto                     Apply all post-install optimizations without prompting.

Connection:
  -p, --password PASSWORD   Specify a password for the VNC connection.
  -vport PORT               Set noVNC port (default: 8080).
  -dns DNS_SERVER[,DNS_SERVER...]  Set DNS server(s), comma-separated (default: auto-detected from rescue system, fallback 1.1.1.1).
  -uefi                     Force UEFI boot mode.
  -legacy                   Force Legacy BIOS boot mode.

Other:
  -h, --help                Show this help message and exit.

Examples:
  $0 -pve -p yourVNCpassword
  $0 -pve -auto -dns 8.8.8.8
  $0 -pbs -no-sub -upgrade
  $0 -pve -fix-sources -no-sub -upgrade -disable-ha
EOF
}

ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case $1 in
        -p | --password)
            if [ -z "${2:-}" ]; then
                echo "Error: -p/--password requires an argument." >&2
                exit 1
            fi
            VNC_PASSWORD="$2"
            shift
            shift
            ;;
        -vport)
            if [ -z "${2:-}" ]; then
                echo "Error: -vport requires a port number." >&2
                exit 1
            fi
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                NOVNC_PORT="$2"
            else
                echo "Error: Invalid port number: $2" >&2
                exit 1
            fi
            shift
            shift
            ;;
        -pve)
            PRODUCT_CHOICE="Proxmox Virtual Environment"
            CLI_PRODUCT_CHOICE="$PRODUCT_CHOICE"
            shift
            ;;
        -pbs)
            PRODUCT_CHOICE="Proxmox Backup Server"
            CLI_PRODUCT_CHOICE="$PRODUCT_CHOICE"
            shift
            ;;
        -pmg)
            PRODUCT_CHOICE="Proxmox Mail Gateway"
            CLI_PRODUCT_CHOICE="$PRODUCT_CHOICE"
            shift
            ;;
        -pdm)
            PRODUCT_CHOICE="Proxmox Datacenter Manager"
            CLI_PRODUCT_CHOICE="$PRODUCT_CHOICE"
            shift
            ;;
        -dns)
            if [ -z "${2:-}" ]; then
                echo "Error: -dns requires a DNS server address." >&2
                exit 1
            fi
            NAME_SERVER=""
            IFS=',' read -ra dns_list <<<"$2"
            for dns_ip in "${dns_list[@]}"; do
                if validate_ipv4 "$dns_ip"; then
                    NAME_SERVER+="${NAME_SERVER:+ }$dns_ip"
                else
                    echo "Warning: Invalid DNS server IP address: $dns_ip. Skipping." >&2
                fi
            done
            if [ -z "$NAME_SERVER" ]; then
                echo "Warning: No valid DNS server IP addresses given. Using fallback 1.0.0.1" >&2
                NAME_SERVER="1.0.0.1"
            fi
            DNS_SOURCE="flag"
            shift
            shift
            ;;
        -uefi)
            USE_UEFI="true"
            shift
            ;;
        -legacy)
            USE_UEFI=""
            BOOT_MODE_SOURCE="flag"
            shift
            ;;
        -fix-sources)
            CLI_FIX_SOURCES="yes"
            shift
            ;;
        -no-sub)
            CLI_NO_SUB="yes"
            shift
            ;;
        -upgrade)
            CLI_UPGRADE="yes"
            shift
            ;;
        -disable-ha)
            CLI_DISABLE_HA="yes"
            shift
            ;;
        -auto)
            CLI_FIX_SOURCES="yes"
            CLI_NO_SUB="yes"
            CLI_UPGRADE="yes"
            CLI_DISABLE_HA="yes"
            shift
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            echo "Warning: Unknown option: $1" >&2
            shift
            ;;
    esac
done

# Check OS: Proxmox supports only Debian and Ubuntu
if [ ! -f /etc/debian_version ]; then
    echo "Error: This script supports only Debian and Ubuntu." >&2
    exit 1
fi

# Check root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root." >&2
    exit 1
fi

# Check KVM availability
if [ ! -c /dev/kvm ]; then
    echo "Error: /dev/kvm not found. KVM is required for acceptable QEMU performance." >&2
    echo "Ensure CPU virtualization (VT-x/AMD-V) is enabled in the rescue environment." >&2
    exit 1
fi

cleanup() {
    pkill -f novnc_proxy 2>/dev/null || true
    printf "quit\n" | nc -w 5 127.0.0.1 "$QEMU_MONITOR_PORT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

clear_list() {
    pkill -f novnc_proxy 2>/dev/null || echo "Note: no noVNC process found." >&2
    echo "All noVNC sessions have been terminated."
    printf "quit\n" | nc -w 5 127.0.0.1 "$QEMU_MONITOR_PORT" 2>/dev/null || echo "Note: QEMU monitor not responding." >&2
    echo "Sent shutdown command to QEMU."
}

print_logo() {
    clear
    echo "$logo"
    echo "Version: $VERSION_SCRIPT"
}

get_network_info() {
    local iface_candidates=()
    local entry
    for entry in /sys/class/net/eth* /sys/class/net/ens* /sys/class/net/enp*; do
        [ -e "$entry" ] && iface_candidates+=("$(basename "$entry")")
    done

    if [ ${#iface_candidates[@]} -eq 0 ]; then
        echo "Error: No valid network interface found." >&2
        exit 1
    fi

    # Take the first matching interface if multiple are found
    local first_iface="${iface_candidates[0]}"

    INTERFACE_NAME=$(udevadm info -q property "/sys/class/net/${first_iface}" | grep "ID_NET_NAME_PATH=" | cut -d'=' -f2 || true)
    if [ -z "$INTERFACE_NAME" ]; then
        # Fallback to the raw interface name if udevadm does not provide a path-based name
        INTERFACE_NAME="$first_iface"
    fi

    MAC_ADDRESS=$(cat "/sys/class/net/${first_iface}/address")

    IP_CIDR=$(ip addr show "$first_iface" | grep "inet\b" | head -n 1 | awk '{print $2}' || true)
    if [ -z "$IP_CIDR" ] || [[ ! "$IP_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "Error: No valid IP configuration found for interface $first_iface" >&2
        exit 1
    fi
    GATEWAY=$(ip route | grep default | awk '{print $3}' || true)
    IP_ADDRESS=$(echo "$IP_CIDR" | cut -d'/' -f1)
    CIDR=$(echo "$IP_CIDR" | cut -d'/' -f2)
}

check_and_install_packages() {
    local required_packages=(curl sshpass dialog git ncat)
    local missing_packages=()
    for package in "${required_packages[@]}"; do
        if ! dpkg -s "$package" >/dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done
    if [ ${#missing_packages[@]} -eq 0 ]; then
        clear
        echo "$logo"
    else
        echo "Installing required packages..."
        apt update -qq || {
            echo "Error: apt update failed." >&2
            exit 1
        }
        for package in "${missing_packages[@]}"; do
            echo "Installing package: $package"
            if ! apt install -y "$package" -qq; then
                echo "Error: Failed to install $package" >&2
                exit 1
            fi
        done
        clear
        echo "$logo"
    fi
}

install_novnc() {
    echo "Checking for noVNC installation..."
    if [ ! -d "$SCRIPT_DIR/noVNC" ]; then
        echo "noVNC not found. Cloning noVNC from GitHub..."
        if [ -n "$NOVNC_VERSION" ]; then
            if ! git clone --branch "$NOVNC_VERSION" --depth 1 https://github.com/novnc/noVNC.git "$SCRIPT_DIR/noVNC"; then
                echo "Error: Failed to clone noVNC repository." >&2
                return 1
            fi
        else
            if ! git clone --depth 1 https://github.com/novnc/noVNC.git "$SCRIPT_DIR/noVNC"; then
                echo "Error: Failed to clone noVNC repository." >&2
                return 1
            fi
        fi
        echo "Cloning websockify for noVNC..."
        if ! git clone --depth 1 https://github.com/novnc/websockify "$SCRIPT_DIR/noVNC/utils/websockify"; then
            echo "Error: Failed to clone websockify repository." >&2
            return 1
        fi
        echo "Renaming vnc.html to index.html..."
        cp "$SCRIPT_DIR/noVNC/vnc.html" "$SCRIPT_DIR/noVNC/index.html"
    else
        echo "noVNC is already installed."
        if [ ! -f "$SCRIPT_DIR/noVNC/index.html" ]; then
            echo "Renaming vnc.html to index.html..."
            cp "$SCRIPT_DIR/noVNC/vnc.html" "$SCRIPT_DIR/noVNC/index.html"
        elif [ ! -f "$SCRIPT_DIR/noVNC/vnc.html" ]; then
            echo "Warning: vnc.html does not exist. Please check your noVNC installation." >&2
        fi
    fi
}

version_gt() {
    [ "$1" = "$2" ] && return 1
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

update_script() {
    local new_script="$1"
    chmod +x "$new_script"
    if [ -f "${BASH_SOURCE[0]:-}" ] && [ -w "${BASH_SOURCE[0]:-}" ]; then
        cp "$new_script" "${BASH_SOURCE[0]}"
        rm -f "$new_script"
        echo "Updated to the new version. Restarting..."
        exec bash "${BASH_SOURCE[0]}" "${ORIGINAL_ARGS[@]}"
    else
        echo "Running the new version (could not overwrite the original script file)..."
        exec bash "$new_script" "${ORIGINAL_ARGS[@]}"
    fi
}

check_for_updates() {
    echo "Checking for updates..."
    local tmp_remote
    tmp_remote=$(mktemp /tmp/proxrescue_update.XXXXXX)
    if ! curl -sfL --connect-timeout 5 --max-time 15 "$SCRIPT_UPDATE_URL" -o "$tmp_remote"; then
        echo "Warning: Could not check for updates." >&2
        rm -f "$tmp_remote"
        return
    fi
    local remote_version
    remote_version=$(grep -m1 '^VERSION_SCRIPT=' "$tmp_remote" | cut -d'"' -f2 || true)
    if [ -z "$remote_version" ]; then
        echo "Warning: Could not determine the latest version." >&2
        rm -f "$tmp_remote"
        return
    fi
    if [ "$remote_version" = "$VERSION_SCRIPT" ]; then
        echo "You are running the latest version ($VERSION_SCRIPT)."
        rm -f "$tmp_remote"
        return
    fi
    if ! version_gt "$remote_version" "$VERSION_SCRIPT"; then
        echo "You are running a newer version ($VERSION_SCRIPT) than the published one ($remote_version)."
        rm -f "$tmp_remote"
        return
    fi
    echo "A new version is available: $remote_version (current: $VERSION_SCRIPT)"
    if [ -n "$CLI_PRODUCT_CHOICE" ]; then
        echo "Non-interactive run: skipping auto-update prompt. Run without flags to update."
        rm -f "$tmp_remote"
        return
    fi
    local answer=""
    read -r -t 30 -p "Download and run the new version now? (Y/n): " answer || true
    if [[ "$answer" =~ ^[Yy]?$ ]]; then
        update_script "$tmp_remote"
    else
        rm -f "$tmp_remote"
    fi
}

apply_post_install_fixes() {
    local root_pass="$1"
    local external_ip="$2"
    echo ""
    echo "Post-install optimizations"
    echo "--------------------------"

    local do_sources="no"
    local do_repos="no"
    local do_update="no"
    local do_disable_ha="no"
    local answer=""

    if [ -n "$CLI_FIX_SOURCES" ]; then
        do_sources="yes"
        echo "  Fix Debian base sources: yes (flag)"
    else
        read -r -p "Fix Debian base sources (deb.debian.org)? (Y/n): " answer
        [[ "$answer" =~ ^[Yy]?$ ]] && do_sources="yes"
    fi

    if [ -n "$CLI_NO_SUB" ]; then
        do_repos="yes"
        echo "  Switch Enterprise repos to no-subscription: yes (flag)"
    else
        read -r -p "Switch Enterprise repos to no-subscription and remove subscription nag? (Y/n): " answer
        [[ "$answer" =~ ^[Yy]?$ ]] && do_repos="yes"
    fi

    if [ "$do_repos" = "yes" ]; then
        if [ -n "$CLI_UPGRADE" ]; then
            do_update="yes"
            echo "  Run apt update + dist-upgrade: yes (flag)"
        else
            read -r -p "Run apt update + dist-upgrade? (Y/n): " answer
            [[ "$answer" =~ ^[Yy]?$ ]] && do_update="yes"
        fi
    else
        echo "  Skipping update: Enterprise repos require a subscription to update."
    fi

    local product_code="pve"
    case "$PRODUCT_NAME" in
        *"Backup Server"*)      product_code="pbs" ;;
        *"Mail Gateway"*)       product_code="pmg" ;;
        *"Datacenter Manager"*) product_code="pdm" ;;
    esac

    if [ "$product_code" = "pve" ]; then
        if [ -n "$CLI_DISABLE_HA" ]; then
            do_disable_ha="yes"
            echo "  Disable HA services: yes (flag)"
        else
            read -r -p "Disable High Availability services (recommended for single-node)? (Y/n): " answer
            [[ "$answer" =~ ^[Yy]?$ ]] && do_disable_ha="yes"
        fi
    fi

    echo ""
    echo "Applying post-install optimizations..."
    local fix_rc=0
    sshpass -f <(printf '%s' "$root_pass") ssh "${QEMU_SSH_OPTS[@]}" -p "$QEMU_SSH_PORT" root@127.0.0.1 \
        bash -s -- "$external_ip" "${NAME_SERVER// /,}" "$do_sources" "$do_repos" "$do_update" "$do_disable_ha" "$product_code" <<'ENDSSH' || fix_rc=$?
EXTERNAL_IP="$1"
REAL_DNS="${2//,/ }"
DO_SOURCES="$3"
DO_REPOS="$4"
DO_UPDATE="$5"
DO_DISABLE_HA="$6"
PRODUCT="$7"
CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")

case "$PRODUCT" in
    pbs) REPO_PREFIX="pbs" ;;
    pmg) REPO_PREFIX="pmg" ;;
    pdm) REPO_PREFIX="pdm" ;;
    *)   REPO_PREFIX="pve" ;;
esac

# Force QEMU SLiRP gateway early — needed for any apt operations below.
# In settings mode the real Hetzner gateway is unreachable inside QEMU's NAT,
# so outbound traffic must go through 10.0.2.2 (QEMU SLiRP default).
QEMU_GW="10.0.2.2"
QEMU_NIC=$(ip -o link show | awk -F': ' '!/LOOPBACK/ && /state UP/{print $2}' | head -1)
if [ -n "$QEMU_NIC" ]; then
    ip route replace default via "$QEMU_GW" dev "$QEMU_NIC" 2>/dev/null || true
    echo "  [+] Default route set via QEMU SLiRP ($QEMU_GW dev $QEMU_NIC)"
fi

if [ "$DO_SOURCES" = "yes" ]; then
    cat >/etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib
deb http://security.debian.org/debian-security ${CODENAME}-security main contrib
EOF
    echo "  [+] Debian base sources corrected (deb.debian.org, ${CODENAME})"
fi

if [ "$DO_REPOS" = "yes" ]; then
    # Repository switch and subscription nag removal logic adapted from
    # community-scripts.org (https://community-scripts.org)
    # Disable enterprise repo (.list format)
    if [ -f /etc/apt/sources.list.d/${REPO_PREFIX}-enterprise.list ]; then
        sed -i 's|^deb |# deb |' /etc/apt/sources.list.d/${REPO_PREFIX}-enterprise.list
    fi
    # Disable enterprise repo (.sources format)
    for f in /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        grep -q "${REPO_PREFIX}-enterprise" "$f" || continue
        grep -q "^Enabled:" "$f" \
            && sed -i 's/^Enabled:.*/Enabled: false/' "$f" \
            || printf 'Enabled: false\n' >> "$f"
    done
    echo "  [+] ${REPO_PREFIX}-enterprise repository disabled"

    # PVE-only: disable ceph enterprise (quincy, reef, squid)
    if [ "$PRODUCT" = "pve" ]; then
        if [ -f /etc/apt/sources.list.d/ceph.list ]; then
            sed -i 's|^deb https://enterprise\.proxmox\.com|# deb https://enterprise.proxmox.com|' \
                /etc/apt/sources.list.d/ceph.list
        fi
        for f in /etc/apt/sources.list.d/*.sources; do
            [ -f "$f" ] || continue
            grep -q "enterprise.proxmox.com.*ceph\|ceph.*enterprise" "$f" || continue
            grep -q "^Enabled:" "$f" \
                && sed -i 's/^Enabled:.*/Enabled: false/' "$f" \
                || printf 'Enabled: false\n' >> "$f"
        done
        echo "  [+] ceph enterprise repository disabled"
    fi

    # Enable no-subscription repo
    echo "deb http://download.proxmox.com/debian/${REPO_PREFIX} ${CODENAME} ${REPO_PREFIX}-no-subscription" \
        > /etc/apt/sources.list.d/${REPO_PREFIX}-no-subscription.list
    echo "  [+] ${REPO_PREFIX}-no-subscription repository enabled (${CODENAME})"

    # apt update so the new repo is visible before reinstall
    apt-get update -qq 2>/dev/null || true

    # Subscription nag removal script — handles web UI + product-specific mobile UI
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/pve-remove-nag.sh << 'NAGSCRIPT'
#!/bin/sh
# Patch desktop web UI (all products)
WEB_JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
if [ -s "$WEB_JS" ] && ! grep -q NoMoreNagging "$WEB_JS"; then
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$WEB_JS"
fi
# Patch PVE mobile UI (PVE 9+)
MOBILE_TPL=/usr/share/pve-yew-mobile-gui/index.html.tpl
MARKER="<!-- MANAGED BLOCK FOR MOBILE NAG -->"
if [ -f "$MOBILE_TPL" ] && ! grep -q "$MARKER" "$MOBILE_TPL"; then
    printf "%s\n" "$MARKER" \
      "<script>" \
      "  function removeSubscriptionElements() {" \
      "    document.querySelectorAll('dialog.pwt-outer-dialog').forEach(d => {" \
      "      if ((d.textContent||'').toLowerCase().includes('subscription')) d.remove();" \
      "    });" \
      "    document.querySelectorAll('.pwt-card.pwt-p-2.pwt-d-flex.pwt-interactive.pwt-justify-content-center').forEach(c => {" \
      "      if (!c.querySelector('button') && (c.textContent||'').toLowerCase().includes('subscription')) c.remove();" \
      "    });" \
      "  }" \
      "  const _nob = new MutationObserver(removeSubscriptionElements);" \
      "  _nob.observe(document.body, { childList: true, subtree: true });" \
      "  removeSubscriptionElements();" \
      "  setInterval(removeSubscriptionElements, 300);" \
      "  setTimeout(() => { _nob.disconnect(); }, 10000);" \
      "</script>" >> "$MOBILE_TPL"
fi
# Patch PMG mobile UI
PMG_JS=/usr/share/javascript/pmg-gui/js/pmgmanagerlib-mobile.js
if [ -s "$PMG_JS" ] && ! grep -q NoMoreNagging "$PMG_JS"; then
    sed -i -e "/data\.status/ s/!//" -e "/data\.status/ s/active/NoMoreNagging/" "$PMG_JS"
fi
NAGSCRIPT
    chmod 755 /usr/local/bin/pve-remove-nag.sh
    printf 'DPkg::Post-Invoke { "/usr/local/bin/pve-remove-nag.sh"; };\n' \
        > /etc/apt/apt.conf.d/no-nag-script
    chmod 644 /etc/apt/apt.conf.d/no-nag-script
    /usr/local/bin/pve-remove-nag.sh

    # Reinstall widget toolkit so nag patch is applied to current files
    case "$PRODUCT" in
        pmg) DEBIAN_FRONTEND=noninteractive apt-get install --reinstall proxmox-widget-toolkit pmg-gui -y -qq 2>/dev/null || true ;;
        pdm) DEBIAN_FRONTEND=noninteractive apt-get install --reinstall proxmox-widget-toolkit proxmox-datacenter-manager -y -qq 2>/dev/null || true ;;
        *)   DEBIAN_FRONTEND=noninteractive apt-get install --reinstall proxmox-widget-toolkit -y -qq 2>/dev/null || true ;;
    esac
    /usr/local/bin/pve-remove-nag.sh
    echo "  [+] Subscription nag removed (clear browser cache after reboot)"
fi

if [ "$DO_UPDATE" = "yes" ]; then
    echo "  [*] Running apt update..."
    apt-get update -qq
    echo "  [*] Running apt dist-upgrade (this may take a while)..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq
    echo "  [+] Packages updated"
fi

if [ "$DO_DISABLE_HA" = "yes" ] && [ "$PRODUCT" = "pve" ]; then
    systemctl disable --now pve-ha-lrm pve-ha-crm corosync 2>/dev/null || true
    echo "  [+] High Availability services disabled (single-node)"
fi

# Fix /etc/hosts: replace installer IP with real external IP
FQDN=$(hostname -f)
SHORT=$(hostname -s)
sed -i "/[[:space:]]${FQDN}\([[:space:]]\|$\)/d" /etc/hosts
echo "${EXTERNAL_IP}    ${FQDN} ${SHORT}" >> /etc/hosts
echo "  [+] /etc/hosts updated: ${EXTERNAL_IP} ${FQDN} ${SHORT}"

# Set real DNS (REAL_DNS may contain one or more space-separated IPs)
: > /etc/resolv.conf
for ns in $REAL_DNS; do
    echo "nameserver $ns" >> /etc/resolv.conf
done
echo "  [+] DNS set: $REAL_DNS"
ENDSSH

    if [ "$fix_rc" -ne 0 ]; then
        echo "Warning: Some post-install fixes failed (exit code: $fix_rc). Continuing..." >&2
    else
        echo "Post-install optimizations applied successfully."
    fi
}

configure_network() {
    get_network_info
    local tmp_netcfg tmp_linkcfg
    tmp_netcfg=$(mktemp /tmp/proxmox_network_config.XXXXXX)
    tmp_linkcfg=$(mktemp /tmp/proxmox_network_link.XXXXXX)
    trap "rm -f '$tmp_netcfg' '$tmp_linkcfg'" RETURN
    cat >"$tmp_linkcfg" <<EOF
[Match]
MACAddress=$MAC_ADDRESS
Type=ether

[Link]
Name=nic0
EOF
    cat >"$tmp_netcfg" <<EOF
auto lo
iface lo inet loopback

iface nic0 inet manual

auto vmbr0
iface vmbr0 inet static
  address $IP_ADDRESS/$CIDR
  gateway $GATEWAY
  bridge_ports nic0
  bridge_stp off
  bridge_fd 0

source /etc/network/interfaces.d/*
EOF
    echo "Setting network in your Server"
    run_qemu "settings"
    while true; do
        read -rs -p "To configure the network on your server, enter the root password you set when installing $PRODUCT_NAME: " ROOT_PASSWORD
        echo ""
        local scp_rc=0
        sshpass -f <(printf '%s' "$ROOT_PASSWORD") ssh "${QEMU_SSH_OPTS[@]}" -p "$QEMU_SSH_PORT" root@127.0.0.1 \
            "mkdir -p /usr/local/lib/systemd/network" || scp_rc=$?
        if [ "$scp_rc" -eq 0 ]; then
            sshpass -f <(printf '%s' "$ROOT_PASSWORD") scp "${QEMU_SSH_OPTS[@]}" -P "$QEMU_SSH_PORT" "$tmp_linkcfg" root@127.0.0.1:/usr/local/lib/systemd/network/50-pmx-nic0.link || scp_rc=$?
        fi
        if [ "$scp_rc" -eq 0 ]; then
            sshpass -f <(printf '%s' "$ROOT_PASSWORD") scp "${QEMU_SSH_OPTS[@]}" -P "$QEMU_SSH_PORT" "$tmp_netcfg" root@127.0.0.1:/etc/network/interfaces || scp_rc=$?
        fi
        case "$scp_rc" in
            0)
                break
                ;;
            5)
                echo "Authorization error. Please check your root password."
                ;;
            *)
                echo "Connection failed (code: $scp_rc). QEMU may still be booting, retrying in 5s..."
                sleep 5
                ;;
        esac
    done
    apply_post_install_fixes "$ROOT_PASSWORD" "$IP_ADDRESS"
    echo "Shutdown QEMU"
    printf "system_powerdown\n" | nc -w 5 127.0.0.1 "$QEMU_MONITOR_PORT" || true
    reboot_server
}

select_disks() {
    local disk_options=()
    local disk_list
    disk_list=$(lsblk -dn -o NAME,TYPE,SIZE -e 1,7,11,14,15 | grep -E 'nvme|sd|vd' | awk '$2 == "disk" {print $1 " " $3}' || true)
    local IFS=$'\n'
    for disk in $disk_list; do
        local disk_name
        disk_name=$(echo "$disk" | awk '{print $1}')
        local disk_size
        disk_size=$(echo "$disk" | awk '{print $2}')
        disk_options+=("$disk_name" "$disk_size" on) # Все диски по умолчанию включены
    done
    local selected_disks_output=""
    local dialog_rc=0
    selected_disks_output=$(dialog --checklist "Select disks to use for QEMU:" 15 50 8 "${disk_options[@]}" 3>&1 1>&2 2>&3 3>&-) || dialog_rc=$?
    if [ "$dialog_rc" -eq 0 ] && [ -n "$selected_disks_output" ]; then
        QEMU_DISK_ARGS=()
        local disk_index=0
        local IFS=' '
        for disk_name in $selected_disks_output; do
            QEMU_DISK_ARGS+=(-drive "file=/dev/${disk_name},format=raw,if=virtio,index=${disk_index},media=disk")
            disk_index=$((disk_index + 1))
        done
    else
        echo "Disk selection cancelled. No changes made."
    fi
    print_logo
}

setup_vnc_and_novnc() {
    sleep 2
    echo "change vnc password $VNC_PASSWORD" | nc -w 5 -q 1 127.0.0.1 "$QEMU_MONITOR_PORT" || true
    print_logo
    echo "Use VNC client or Web Browser to connect to your server."
    echo -e "IP for VNC connect: $IP_ADDRESS\n"
    echo "For NoVNC open in browser http://$IP_ADDRESS:$NOVNC_PORT"
    echo -e "\nYour password for connect: \033[1m$VNC_PASSWORD\033[0m\n"
    "$SCRIPT_DIR/noVNC/utils/novnc_proxy" --vnc "127.0.0.1:$QEMU_VNC_PORT" --listen "$IP_ADDRESS:$NOVNC_PORT" >/dev/null 2>&1 &
    NOVNC_PID=$!
}

is_qemu_running() {
    pgrep -f "qemu-system-x86_64" >/dev/null 2>&1
}

wait_for_qemu() {
    local prompt_msg="$1"
    local confirm_word="$2"
    local stop_cmd="$3"
    local on_done="$4"

    while true; do
        if ! is_qemu_running; then
            echo "QEMU process has stopped unexpectedly." >&2
            kill "$NOVNC_PID" 2>/dev/null || true
            echo "noVNC stopped."
            echo "Options: 1) Return to menu  2) Reboot server"
            read -r -p "Choice (1/2): " fail_choice
            case "$fail_choice" in
                2) reboot_server ;;
                *) return ;;
            esac
            break
        fi
        local confirmation=""
        printf "\r\033[K%s" "$prompt_msg"
        read -r -t 5 confirmation || true
        if [ "$confirmation" = "$confirm_word" ]; then
            echo "QEMU shutting down..."
            printf "%s\n" "$stop_cmd" | nc -w 5 127.0.0.1 "$QEMU_MONITOR_PORT" || true
            kill "$NOVNC_PID" 2>/dev/null || true
            echo "noVNC stopped."
            if [ -n "$on_done" ]; then
                $on_done
            fi
            break
        fi
    done
}

build_qemu_args() {
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        echo "Error: qemu-system-x86_64 not found. Install: apt install qemu-system-x86" >&2
        return 1
    fi
    get_network_info
    if [ ${#QEMU_DISK_ARGS[@]} -eq 0 ]; then
        local disks
        disks=$(lsblk -dn -o NAME,TYPE -e 1,7,11,14,15 | grep -E 'nvme|sd|vd' | awk '$2 == "disk" {print $1}' || true)
        local disk_index=0
        for disk in $disks; do
            QEMU_DISK_ARGS+=(-drive "file=/dev/${disk},format=raw,if=virtio,index=${disk_index},media=disk")
            disk_index=$((disk_index + 1))
        done
        if [ ${#QEMU_DISK_ARGS[@]} -eq 0 ]; then
            echo "Error: No suitable disks found on the system." >&2
            return 1
        fi
    fi

    QEMU_COMMON_ARGS=(-daemonize -enable-kvm -m "$QEMU_MEMORY" -vnc ":0,password=on" -monitor "telnet:127.0.0.1:$QEMU_MONITOR_PORT,server,nowait")

    if [ "$USE_UEFI" = "true" ]; then
        if [ ! -f "$OVMF_PATH" ]; then
            echo "Error: OVMF firmware not found at $OVMF_PATH. Install: apt install ovmf" >&2
            return 1
        fi
        QEMU_COMMON_ARGS=(-bios "$OVMF_PATH" "${QEMU_COMMON_ARGS[@]}")
    fi
}

run_qemu_install() {
    local QEMU_CDROM_ARGS=(-drive "file=/tmp/proxmox.iso,index=0,media=cdrom" -boot d)
    qemu-system-x86_64 "${QEMU_COMMON_ARGS[@]}" "${QEMU_DISK_ARGS[@]}" "${QEMU_CDROM_ARGS[@]}"
    echo -e "\nQemu running...."
    setup_vnc_and_novnc
    wait_for_qemu \
        "Installation in progress... Enter 'yes' when complete: " \
        "yes" \
        "quit" \
        "configure_network"
}

run_qemu_settings() {
    local QEMU_NETWORK_SETTINGS=(-net "user,hostfwd=tcp::${QEMU_SSH_PORT}-:22" -net nic)
    qemu-system-x86_64 "${QEMU_COMMON_ARGS[@]}" "${QEMU_DISK_ARGS[@]}" "${QEMU_NETWORK_SETTINGS[@]}"
}

run_qemu_runsystem() {
    qemu-system-x86_64 "${QEMU_COMMON_ARGS[@]}" "${QEMU_DISK_ARGS[@]}"
    echo -e "\nQemu running...."
    setup_vnc_and_novnc
    wait_for_qemu \
        "System running... Enter 'shutdown' to stop QEMU: " \
        "shutdown" \
        "system_powerdown" \
        "reboot_server"
}

run_qemu() {
    local task=$1
    if [ "$task" != "settings" ]; then
        if pgrep -f "qemu-system-x86_64" >/dev/null 2>&1; then
            echo "Error: QEMU is already running. Stop it before starting a new instance." >&2
            return 1
        fi
    else
        # "settings" is called right after install QEMU received "quit" — wait for clean exit
        local retries=10
        while pgrep -f "qemu-system-x86_64" >/dev/null 2>&1; do
            if [ "$retries" -le 0 ]; then
                echo "Error: Previous QEMU instance did not exit in time." >&2
                return 1
            fi
            sleep 1
            retries=$((retries - 1))
        done
    fi
    build_qemu_args || return 1
    case "$task" in
        install) run_qemu_install ;;
        settings) run_qemu_settings ;;
        runsystem) run_qemu_runsystem ;;
    esac
}

verify_iso_checksum() {
    local iso_name="$1"
    local iso_path="${2:-/tmp/proxmox.iso}"
    echo "Downloading SHA256SUMS for verification..."
    # Always fetch checksums over HTTPS to prevent MITM tampering
    if ! curl -sfL --connect-timeout 10 --max-time 30 "https://download.proxmox.com/iso/SHA256SUMS" -o /tmp/proxmox_sha256sums; then
        echo "Warning: Could not download SHA256SUMS file." >&2
        read -r -p "Continue without checksum verification? (y/N): " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            return 0
        fi
        return 1
    fi
    local expected_hash
    expected_hash=$(grep "$iso_name" /tmp/proxmox_sha256sums | awk '{print $1}')
    if [ -z "$expected_hash" ]; then
        echo "Warning: No checksum found for $iso_name in SHA256SUMS. Skipping verification." >&2
        rm -f /tmp/proxmox_sha256sums
        return 0
    fi
    echo "Verifying SHA256 checksum..."
    local actual_hash
    actual_hash=$(sha256sum "$iso_path" | awk '{print $1}')
    rm -f /tmp/proxmox_sha256sums
    if [ "$expected_hash" = "$actual_hash" ]; then
        echo "SHA256 checksum verified successfully."
        return 0
    else
        echo "Expected: $expected_hash"
        echo "Got:      $actual_hash"
        return 1
    fi
}

select_product() {
    if [ -n "$PRODUCT_CHOICE" ]; then
        echo "Product has been already selected: $PRODUCT_CHOICE"
        case "$PRODUCT_CHOICE" in
            "Proxmox Virtual Environment")
                GREP_PATTERN='proxmox-ve_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Virtual Environment"
                ;;
            "Proxmox Backup Server")
                GREP_PATTERN='proxmox-backup-server_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Backup Server"
                ;;
            "Proxmox Mail Gateway")
                GREP_PATTERN='proxmox-mail-gateway_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Mail Gateway"
                ;;
            "Proxmox Datacenter Manager")
                GREP_PATTERN='proxmox-datacenter-manager_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Datacenter Manager"
                ;;
        esac
        return 0
    fi

    while true; do
        print_logo
        echo "Select the Proxmox product to install:"
        echo "1) Proxmox Virtual Environment"
        echo "2) Proxmox Backup Server"
        echo "3) Proxmox Mail Gateway"
        echo "4) Proxmox Datacenter Manager"
        echo "5) Return to main menu"
        read -r -p "Enter number (1-5): " product_choice

        case "$product_choice" in
            1)
                GREP_PATTERN='proxmox-ve_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Virtual Environment"
                return 0
                ;;
            2)
                GREP_PATTERN='proxmox-backup-server_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Backup Server"
                return 0
                ;;
            3)
                GREP_PATTERN='proxmox-mail-gateway_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Mail Gateway"
                return 0
                ;;
            4)
                GREP_PATTERN='proxmox-datacenter-manager_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                PRODUCT_NAME="Proxmox Datacenter Manager"
                return 0
                ;;
            5)
                echo "Returning to main menu..."
                return 1
                ;;
            *) echo "Invalid selection. Please, try again." ;;
        esac
    done
}

fetch_available_versions() {
    print_logo
    echo "Retrieving available versions for $PRODUCT_NAME..."
    local iso_page=""
    if ! iso_page=$(curl -sfL --connect-timeout 10 --max-time 30 "${PROXMOX_MIRROR}/iso/"); then
        echo "Warning: HTTPS failed. Retrying over HTTP..." >&2
        PROXMOX_MIRROR="http://download.proxmox.com"
        if ! iso_page=$(curl -sfL --connect-timeout 10 --max-time 30 "${PROXMOX_MIRROR}/iso/"); then
            echo "Error: Both HTTPS and HTTP failed. Check network connection." >&2
            return 1
        fi
    fi
    if [ -z "$iso_page" ]; then
        echo "Error: Empty response from download.proxmox.com." >&2
        return 1
    fi
    AVAILABLE_ISOS=$(echo "$iso_page" | grep -oP "$GREP_PATTERN" | sort -V | tac | uniq || true)
    if [ -z "$AVAILABLE_ISOS" ]; then
        echo "Error: No ISO versions found for $PRODUCT_NAME." >&2
        return 1
    fi
    IFS=$'\n' read -r -d '' -a iso_array <<<"$AVAILABLE_ISOS" || true
}

select_version() {
    echo "Please select the version to install (default is the latest version):"
    for i in "${!iso_array[@]}"; do
        echo "$((i + 1))) ${iso_array[i]}"
    done
    echo "$((${#iso_array[@]} + 1))) Return to product selection"
    echo "$((${#iso_array[@]} + 2))) Return to main menu"

    if [ -n "$CLI_PRODUCT_CHOICE" ]; then
        version_choice=1
        echo "Auto-selected the latest version (non-interactive run)."
    else
        read -r -t 30 -p "Enter number (1-$((${#iso_array[@]} + 2))) or wait for auto-selection: " version_choice || true
        if [ -z "${version_choice:-}" ]; then
            version_choice=1
            echo "Auto-selected the latest version due to timeout."
        fi
    fi

    if [ "$version_choice" -eq "$((${#iso_array[@]} + 1))" ]; then
        echo "Returning to product selection..."
        SELECTED_ISO=""
        return 2
    elif [ "$version_choice" -eq "$((${#iso_array[@]} + 2))" ]; then
        echo "Returning to main menu..."
        SELECTED_ISO=""
        return 1
    elif [[ "$version_choice" =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le "${#iso_array[@]}" ]; then
        SELECTED_ISO="${iso_array[$((version_choice - 1))]}"
    else
        echo "Invalid selection, using the latest version."
        SELECTED_ISO="${iso_array[0]}"
    fi
}

download_and_verify_iso() {
    local selected_iso="$1"

    if [ -f /tmp/proxmox.iso ]; then
        echo "Found existing /tmp/proxmox.iso"
        read -r -p "Re-download? (y/N): " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    local iso_url="${PROXMOX_MIRROR}/iso/$selected_iso"
    local tmp_iso="/tmp/proxmox_download_$$.iso"
    echo "Downloading $iso_url..."
    if ! curl -fL --connect-timeout 10 "$iso_url" -o "$tmp_iso" --progress-bar; then
        echo "Error: Failed to download ISO from $iso_url" >&2
        rm -f "$tmp_iso"
        return 1
    fi
    if ! verify_iso_checksum "$selected_iso" "$tmp_iso"; then
        echo "SHA256 checksum verification FAILED. The downloaded ISO may be corrupted or tampered with." >&2
        echo "Please try downloading again or verify manually." >&2
        rm -f "$tmp_iso"
        return 1
    fi
    mv "$tmp_iso" /tmp/proxmox.iso
}

select_proxmox_product_and_version() {
    while true; do
        select_product || return

        fetch_available_versions || return

        local version_rc=0
        select_version || version_rc=$?
        if [ "$version_rc" -eq 2 ]; then
            PRODUCT_CHOICE=""
            continue
        elif [ "$version_rc" -eq 1 ]; then
            return
        fi

        if [ -z "$SELECTED_ISO" ]; then
            return
        fi

        download_and_verify_iso "$SELECTED_ISO" || return

        print_logo
        run_qemu "install"
        return
    done
}

reboot_server() {
    echo "Are you sure you want to reboot the server? (Y/n)"
    read -r answer
    if [[ $answer =~ ^[Yy]?$ ]]; then
        echo "Rebooting in $REBOOT_TIMEOUT seconds..."
        sleep "$REBOOT_TIMEOUT"
        shutdown -r now
    else
        echo "Reboot canceled. Returning to main menu..."
        return
    fi
}

runInstalledSystem() {
    run_qemu "runsystem"
}

changeVncPassword() {
    echo "Enter new password for VNC:"
    read -rs VNC_PASSWORD
    echo
    echo "change vnc password $VNC_PASSWORD" | nc -w 5 -q 1 127.0.0.1 "$QEMU_MONITOR_PORT" || {
        echo "Warning: Could not send new VNC password to QEMU monitor." >&2
    }
    echo -e "VNC password updated to: \033[1m$VNC_PASSWORD\033[0m"
}

exitScript() {
    echo "Exiting script."
    exit 0
}

changeDnsServer() {
    echo "Current DNS server(s): $NAME_SERVER"
    read -r -p "Enter new DNS server(s), comma-separated (e.g. 8.8.8.8,1.1.1.1): " dns_input
    if [ -z "$dns_input" ]; then
        echo "No input given. DNS server(s) unchanged."
        return
    fi
    local new_servers="" dns_ip
    IFS=',' read -ra dns_list <<<"$dns_input"
    for dns_ip in "${dns_list[@]}"; do
        if validate_ipv4 "$dns_ip"; then
            new_servers+="${new_servers:+ }$dns_ip"
        else
            echo "Warning: Invalid DNS server IP address: $dns_ip. Skipping." >&2
        fi
    done
    if [ -z "$new_servers" ]; then
        echo "No valid DNS server IP addresses given. DNS server(s) unchanged."
        return
    fi
    NAME_SERVER="$new_servers"
    DNS_SOURCE="flag"
    echo "DNS server(s) updated to: $NAME_SERVER"
}

toggle_uefi_mode() {
    if [ "$USE_UEFI" = "true" ]; then
        USE_UEFI=""
        BOOT_MODE_SOURCE="manual"
        echo "Boot mode switched to: Legacy BIOS"
    else
        USE_UEFI=true
        BOOT_MODE_SOURCE="manual"
        echo "Boot mode switched to: UEFI"
        if [ ! -f "$OVMF_PATH" ]; then
            echo "Warning: OVMF firmware not found at $OVMF_PATH. Install: apt install ovmf" >&2
        fi
    fi
}

show_menu() {
    while true; do
        local mode_label source_label
        [ "$USE_UEFI" = "true" ] && mode_label="UEFI" || mode_label="Legacy BIOS"
        [ "$BOOT_MODE_SOURCE" = "auto" ] && source_label="auto-detected" || source_label="manually set"

        echo "Welcome to Proxmox products installer in Rescue Mode for Hetzner"
        echo "================================================================"
        echo "Boot mode: $mode_label ($source_label)"
        echo "DNS server(s): $NAME_SERVER ($([ "$DNS_SOURCE" = "flag" ] && echo "forced via -dns" || echo "auto-detected"))"
        echo "----------------------------------------------------------------"
        echo "Please choose an action:"
        echo "1) Select disks for QEMU"
        echo "2) Install Proxmox (PVE, PBS, PMG, PDM)"
        echo "3) Run installed System in QEMU"
        echo "4) Toggle boot mode (current: $mode_label)"
        echo "5) Change VNC Password"
        echo "6) Change DNS server(s)"
        echo "7) Reboot"
        echo "8) Exit"

        read -r -p "Enter choice: " choice
        case "$choice" in
            1) select_disks ;;
            2) select_proxmox_product_and_version ;;
            3) runInstalledSystem ;;
            4) toggle_uefi_mode ;;
            5) changeVncPassword ;;
            6) changeDnsServer ;;
            7)
                reboot_server
                return
                ;;
            8) exitScript ;;
            *)
                echo "Invalid selection. Please, try again." >&2
                ;;
        esac
    done
}

check_and_install_packages
check_for_updates
install_novnc
clear_list
detect_boot_mode
detect_dns_server

print_logo
if [ -n "$PRODUCT_CHOICE" ]; then
    select_proxmox_product_and_version
fi
show_menu
