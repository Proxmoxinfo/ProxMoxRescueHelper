#!/bin/bash
set -euo pipefail

# ============================================================================================
#  ██████  ██████   ██████  ██   ██ ███    ███  ██████  ██   ██    ██ ███    ██ ███████  ██████
# ██   ██ ██   ██ ██    ██  ██ ██  ████  ████ ██    ██  ██ ██     ██ ████   ██ ██      ██    ██
# ██████  ██████  ██    ██   ███   ██ ████ ██ ██    ██   ███      ██ ██ ██  ██ █████   ██    ██
# ██      ██   ██ ██    ██  ██ ██  ██  ██  ██ ██    ██  ██ ██     ██ ██  ██ ██ ██      ██    ██
# ██      ██   ██  ██████  ██   ██ ██      ██  ██████  ██   ██ ██ ██ ██   ████ ██       ██████
#
# Proxmox Products Installer in Rescue Mode for Hetzner
#
# © 2024 Proxmox UA www.proxmox.info. Все права защищены.
#
# Сообщества и поддержка:
# - Telegram:https://t.me/Proxmox_UA
# - GitHub: https://github.com/Proxmoxinfo/ProxMoxRescueHelper
# - Website: https://proxmox.info
#
# Этот скрипт предназначен для установки продуктов Proxmox в режиме восстановления на серверах Hetzner.
# ============================================================================================

# shellcheck disable=SC2034
VERSION_SCRIPT="0.70"
# shellcheck disable=SC2034
SCRIPT_TYPE="self-contained"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ports
QEMU_MONITOR_PORT=4444
QEMU_VNC_PORT=5900
QEMU_SSH_PORT=2222

# Paths
OVMF_PATH="/usr/share/ovmf/OVMF.fd"

# UX
DISK_WARNING_ENABLED=true
REBOOT_TIMEOUT=5

# noVNC
NOVNC_VERSION=""

logo='
██████  ██████   ██████  ██   ██ ███    ███  ██████  ██   ██    ██ ███    ██ ███████  ██████  
██   ██ ██   ██ ██    ██  ██ ██  ████  ████ ██    ██  ██ ██     ██ ████   ██ ██      ██    ██ 
██████  ██████  ██    ██   ███   ██ ████ ██ ██    ██   ███      ██ ██ ██  ██ █████   ██    ██ 
██      ██   ██ ██    ██  ██ ██  ██  ██  ██ ██    ██  ██ ██     ██ ██  ██ ██ ██      ██    ██ 
██      ██   ██  ██████  ██   ██ ██      ██  ██████  ██   ██ ██ ██ ██   ████ ██       ██████  
'

VNC_PASSWORD=""
VNC_PASSWORD_LENGTH=10 # min 8, max 20
PRODUCT_CHOICE=""
NOVNC_PORT=""
USE_UEFI=""
NAME_SERVER="1.1.1.1"

QEMU_MEMORY="3000" # in megabytes
QEMU_DISK_ARGS=()

if [ -z "$VNC_PASSWORD" ]; then
    if [ "$VNC_PASSWORD_LENGTH" -lt 8 ] || [ "$VNC_PASSWORD_LENGTH" -gt 20 ]; then
        echo "Warning: VNC_PASSWORD_LENGTH must be between 8 and 20. Using default (10)." >&2
        VNC_PASSWORD_LENGTH=10
    fi
    VNC_PASSWORD=$(head -c 256 /dev/urandom | tr -dc A-Za-z0-9 | head -c "$VNC_PASSWORD_LENGTH")
fi
if [ -z "$NOVNC_PORT" ]; then
    NOVNC_PORT=8080
fi

show_help() {
    echo "$logo"
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -ve                       Install Proxmox Virtual Environment."
    echo "  -bs                       Install Proxmox Backup Server."
    echo "  -mg                       Install Proxmox Mail Gateway."
    echo "  -vport                    Set noVNC port (default 8080)."
    echo "  -p, --password PASSWORD   Specify a password for the VNC connection."
    echo "  -dns DNS_SERVER            Set DNS server (default 1.1.1.1)."
    echo "  -uefi                     Use UEFI for installation or system run."
    echo "  -h, --help                Show this help message and exit."
    echo ""
    echo "Example:"
    echo "  $0 -ve -p yourVNCpassword   Install Proxmox VE with a specified VNC password."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p | --password)
            VNC_PASSWORD="$2"
            shift
            shift
            ;;
        -vport)
            if [[ "$2" =~ ^[0-9]+$ ]] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ]; then
                NOVNC_PORT="$2"
            else
                echo "Error: Invalid port number: $2" >&2
                exit 1
            fi
            shift
            shift
            ;;
        -ve)
            PRODUCT_CHOICE="Proxmox Virtual Environment"
            shift
            ;;
        -bs)
            PRODUCT_CHOICE="Proxmox Backup Server"
            shift
            ;;
        -mg)
            PRODUCT_CHOICE="Proxmox Mail Gateway"
            shift
            ;;
        -dns)
            if [[ "$2" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                NAME_SERVER="$2"
            else
                echo "Warning: Invalid DNS server IP address: $2. Using fallback 1.0.0.1" >&2
                NAME_SERVER="1.0.0.1"
            fi
            shift
            shift
            ;;
        -uefi)
            USE_UEFI="true"
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

clear_list() {
    pkill -f novnc_proxy || true
    echo "All noVNC sessions have been terminated."
    ssh-keygen -R "[127.0.0.1]:$QEMU_SSH_PORT" || true
    echo "SSH key cache cleared for 127.0.0.1 port $QEMU_SSH_PORT."
    printf "quit\n" | nc 127.0.0.1 "$QEMU_MONITOR_PORT" || true
    echo "Sent shutdown command to QEMU."
}

print_logo() {
    clear
    echo "$logo"
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

    IP_CIDR=$(ip addr show "$INTERFACE_NAME" | grep "inet\b" | head -n 1 | awk '{print $2}' || true)
    if [ -z "$IP_CIDR" ] || [[ ! "$IP_CIDR" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
        echo "Error: No valid IP configuration found for interface $INTERFACE_NAME" >&2
        exit 1
    fi
    GATEWAY=$(ip route | grep default | awk '{print $3}' || true)
    IP_ADDRESS=$(echo "$IP_CIDR" | cut -d'/' -f1)
    CIDR=$(echo "$IP_CIDR" | cut -d'/' -f2)
}

check_and_install_packages() {
    local required_packages=(curl sshpass dialog)
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
    if [ ! -d "noVNC" ]; then
        echo "noVNC not found. Cloning noVNC from GitHub..."
        if ! git clone https://github.com/novnc/noVNC.git; then
            echo "Error: Failed to clone noVNC repository." >&2
            return 1
        fi
        echo "Cloning websockify for noVNC..."
        if ! git clone https://github.com/novnc/websockify noVNC/utils/websockify; then
            echo "Error: Failed to clone websockify repository." >&2
            return 1
        fi
        echo "Renaming vnc.html to index.html..."
        cp noVNC/vnc.html noVNC/index.html
    else
        echo "noVNC is already installed."
        if [ ! -f "noVNC/index.html" ]; then
            echo "Renaming vnc.html to index.html..."
            cp noVNC/vnc.html noVNC/index.html
        elif [ ! -f "noVNC/vnc.html" ]; then
            echo "Warning: vnc.html does not exist. Please check your noVNC installation." >&2
        fi
    fi
}

configure_network() {
    get_network_info
    local tmp_netcfg
    tmp_netcfg=$(mktemp /tmp/proxmox_network_config.XXXXXX)
    trap 'rm -f "$tmp_netcfg"' RETURN
    cat >"$tmp_netcfg" <<EOF
auto lo
iface lo inet loopback

iface $INTERFACE_NAME inet manual

auto vmbr0
iface vmbr0 inet static
  address $IP_ADDRESS/$CIDR
  gateway $GATEWAY
  bridge_ports $INTERFACE_NAME
  bridge_stp off
  bridge_fd 0
EOF
    echo "Setting network in your Server"
    run_qemu "settings"
    while true; do
        read -rs -p "To configure the network on your server, enter the root password you set when installing $PRODUCT_NAME: " ROOT_PASSWORD
        local scp_rc=0
        sshpass -p "$ROOT_PASSWORD" scp -o StrictHostKeyChecking=no -P "$QEMU_SSH_PORT" "$tmp_netcfg" root@127.0.0.1:/etc/network/interfaces || scp_rc=$?
        if [ "$scp_rc" -eq 5 ]; then
            echo "Authorization error. Please check your root password." >&2
        else
            break
        fi
    done
    local ssh_rc=0
    sshpass -p "$ROOT_PASSWORD" ssh -o StrictHostKeyChecking=no -p "$QEMU_SSH_PORT" root@127.0.0.1 "sed -i 's|nameserver.*|nameserver $NAME_SERVER|' /etc/resolv.conf" || ssh_rc=$?
    if [ "$ssh_rc" -ne 0 ]; then
        echo "Error in change resolv.conf." >&2
    else
        echo "resolv.conf updated."
        echo "Shutdown QEMU"
        printf "system_powerdown\n" | nc 127.0.0.1 "$QEMU_MONITOR_PORT" || true
        reboot_server
    fi
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
        for disk_name in $selected_disks_output; do
            QEMU_DISK_ARGS+=(-drive "file=/dev/${disk_name},format=raw,if=virtio,index=${disk_index},media=disk")
            disk_index=$((disk_index + 1))
        done
    else
        echo "Disk selection cancelled. No changes made."
    fi
    print_logo
}

run_qemu() {
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        echo "Error: qemu-system-x86_64 not found. Install: apt install qemu-system-x86" >&2
        return 1
    fi
    get_network_info
    local task=$1
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

    local QEMU_COMMON_ARGS=(-daemonize -enable-kvm -m "$QEMU_MEMORY" -vnc ":0,password=on" -monitor "telnet:127.0.0.1:$QEMU_MONITOR_PORT,server,nowait")

    if [ "$USE_UEFI" = "true" ]; then
        if [ ! -f "/usr/share/ovmf/OVMF.fd" ]; then
            echo "Error: OVMF firmware not found. Install: apt install ovmf" >&2
            return 1
        fi
        QEMU_COMMON_ARGS=(-bios /usr/share/ovmf/OVMF.fd "${QEMU_COMMON_ARGS[@]}")
    fi
    if [ "$task" = "install" ]; then
        local QEMU_CDROM_ARGS=(-drive "file=/tmp/proxmox.iso,index=0,media=cdrom" -boot d)
        qemu-system-x86_64 "${QEMU_COMMON_ARGS[@]}" "${QEMU_DISK_ARGS[@]}" "${QEMU_CDROM_ARGS[@]}"
        echo -e "\nQemu running...."
        sleep 2
        echo "change vnc password $VNC_PASSWORD" | nc -q 1 127.0.0.1 "$QEMU_MONITOR_PORT" || true
        print_logo
        echo "Use VNC client or Use Web Browser for connect to your server."
        echo -e "Ip for vnc connect:  $IP_ADDRESS\n"
        echo "For use NoVNC open in browser http://$IP_ADDRESS:$NOVNC_PORT"
        echo -e "\nYour password for connect: \033[1m$VNC_PASSWORD\033[0m\n"
        ./noVNC/utils/novnc_proxy --vnc 127.0.0.1:$QEMU_VNC_PORT --listen "$IP_ADDRESS:$NOVNC_PORT" >/dev/null 2>&1 &
        NOVNC_PID=$!
        while true; do
            # pgrep is used here because qemu runs with -daemonize (no direct PID)
            if ! pgrep -f "qemu-system-x86_64" >/dev/null; then
                echo "QEMU process has stopped unexpectedly." >&2
                kill "$NOVNC_PID" 2>/dev/null || true
                echo "noVNC stopped."
                reboot_server
                break
            fi
            confirmation=""
            read -r -t 5 -p "Installation in progress... Enter 'yes' when complete: " confirmation || true
            if [ "$confirmation" = "yes" ]; then
                echo "QEMU shutting down...."
                printf "quit\n" | nc 127.0.0.1 "$QEMU_MONITOR_PORT" || true
                kill "$NOVNC_PID" 2>/dev/null || true
                echo "noVNC stopped."
                print_logo
                configure_network
                break
            fi
        done
    elif [ "$task" = "settings" ]; then
        local QEMU_NETWORK_SETTINGS=(-net "user,hostfwd=tcp::${QEMU_SSH_PORT}-:22" -net nic)
        qemu-system-x86_64 "${QEMU_COMMON_ARGS[@]}" "${QEMU_DISK_ARGS[@]}" "${QEMU_NETWORK_SETTINGS[@]}"
    elif [ "$task" = "runsystem" ]; then
        qemu-system-x86_64 "${QEMU_COMMON_ARGS[@]}" "${QEMU_DISK_ARGS[@]}" &
        QEMU_PID=$!
        echo -e "\nQemu running...."
        sleep 2
        echo "change vnc password $VNC_PASSWORD" | nc -q 1 127.0.0.1 "$QEMU_MONITOR_PORT" || true
        print_logo
        echo "Use VNC client or Use Web Browser for connect to your server."
        echo -e "Ip for vnc connect:  $IP_ADDRESS\n"
        echo "For use NoVNC open in browser http://$IP_ADDRESS:$NOVNC_PORT"
        echo -e "\nYour password for connect: \033[1m$VNC_PASSWORD\033[0m\n"
        ./noVNC/utils/novnc_proxy --vnc 127.0.0.1:$QEMU_VNC_PORT --listen "$IP_ADDRESS:$NOVNC_PORT" >/dev/null 2>&1 &
        NOVNC_PID=$!
        while true; do
            if ! kill -0 "$QEMU_PID" 2>/dev/null; then
                echo "QEMU process has stopped unexpectedly." >&2
                kill "$NOVNC_PID" 2>/dev/null || true
                echo "noVNC stopped."
                reboot_server
                break
            fi
            confirmation=""
            read -r -t 5 -p "System running... Enter 'shutdown' to stop QEMU: " confirmation || true
            if [ "$confirmation" = "shutdown" ]; then
                echo "QEMU shutting down manually..."
                printf "system_powerdown\n" | nc 127.0.0.1 "$QEMU_MONITOR_PORT" || true
                kill "$NOVNC_PID" 2>/dev/null || true
                echo "noVNC stopped."
                reboot_server
                break
            fi
        done
    fi
}

verify_iso_checksum() {
    local iso_name="$1"
    local iso_path="${2:-/tmp/proxmox.iso}"
    echo "Downloading SHA256SUMS for verification..."
    if ! curl -sf "https://download.proxmox.com/iso/SHA256SUMS" -o /tmp/proxmox_sha256sums; then
        echo "Warning: Could not download SHA256SUMS file. Skipping verification." >&2
        return 0
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

select_proxmox_product_and_version() {
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
        esac
    else
        local valid_choice=0
        while [ $valid_choice -eq 0 ]; do
            print_logo
            echo "Select the Proxmox product to install:"
            echo "1) Proxmox Virtual Environment"
            echo "2) Proxmox Backup Server"
            echo "3) Proxmox Mail Gateway"
            echo "4) Return to main menu"
            read -r -p "Enter number (1-4): " product_choice

            case "$product_choice" in
                1)
                    GREP_PATTERN='proxmox-ve_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                    PRODUCT_NAME="Proxmox Virtual Environment"
                    valid_choice=1
                    ;;
                2)
                    GREP_PATTERN='proxmox-backup-server_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                    PRODUCT_NAME="Proxmox Backup Server"
                    valid_choice=1
                    ;;
                3)
                    GREP_PATTERN='proxmox-mail-gateway_([0-9]+\.[0-9]+-[0-9]+)\.iso'
                    PRODUCT_NAME="Proxmox Mail Gateway"
                    valid_choice=1
                    ;;
                4)
                    echo "Returning to main menu..."
                    return
                    ;;
                *) echo "Invalid selection. Please, try again." >&2 ;;
            esac
        done
    fi

    print_logo
    echo "Retrieving available versions for $PRODUCT_NAME..."
    local iso_page=""
    if ! iso_page=$(curl -sf 'https://download.proxmox.com/iso/'); then
        echo "Error: Failed to retrieve ISO list from download.proxmox.com." >&2
        echo "Please check your network connection and try again." >&2
        return
    fi
    if [ -z "$iso_page" ]; then
        echo "Error: Empty response from download.proxmox.com." >&2
        return
    fi
    AVAILABLE_ISOS=$(echo "$iso_page" | grep -oP "$GREP_PATTERN" | sort -V | tac | uniq || true)
    if [ -z "$AVAILABLE_ISOS" ]; then
        echo "Error: No ISO versions found for $PRODUCT_NAME." >&2
        return
    fi
    IFS=$'\n' read -r -d '' -a iso_array <<<"$AVAILABLE_ISOS" || true
    echo "Please select the version to install (default is the latest version):"
    for i in "${!iso_array[@]}"; do
        echo "$((i + 1))) ${iso_array[i]}"
    done
    echo "$((${#iso_array[@]} + 1)) Return to product selection"
    echo "$((${#iso_array[@]} + 2)) Return to main menu"

    read -r -t 30 -p "Enter number (1-$((${#iso_array[@]} + 2))) or wait for auto-selection: " version_choice || true
    if [ -z "${version_choice:-}" ]; then
        version_choice=1
        echo "Auto-selected the latest version due to timeout."
    fi

    if [ "$version_choice" -eq "$((${#iso_array[@]} + 1))" ]; then
        echo "Returning to product selection..."
        select_proxmox_product_and_version
        return
    elif [ "$version_choice" -eq "$((${#iso_array[@]} + 2))" ]; then
        echo "Returning to main menu..."
        return
    elif [[ "$version_choice" =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le "${#iso_array[@]}" ]; then
        selected_iso="${iso_array[$((version_choice - 1))]}"
    else
        echo "Invalid selection, using the latest version." >&2
        selected_iso="${iso_array[0]}"
    fi

    ISO_URL="https://download.proxmox.com/iso/$selected_iso"
    local tmp_iso="/tmp/proxmox_download_$$.iso"
    echo "Downloading $ISO_URL..."
    if ! curl -f "$ISO_URL" -o "$tmp_iso" --progress-bar; then
        echo "Error: Failed to download ISO from $ISO_URL" >&2
        rm -f "$tmp_iso"
        return
    fi
    if ! verify_iso_checksum "$selected_iso" "$tmp_iso"; then
        echo "SHA256 checksum verification FAILED. The downloaded ISO may be corrupted or tampered with." >&2
        echo "Please try downloading again or verify manually." >&2
        rm -f "$tmp_iso"
        return
    fi
    mv "$tmp_iso" /tmp/proxmox.iso
    print_logo
    run_qemu "install"
}

reboot_server() {
    echo "Are you sure you want to reboot the server? (Y/n)"
    read -r answer
    if [[ $answer =~ ^[Yy]?$ ]]; then
        echo "Rebooting..."
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
    read -r VNC_PASSWORD
    echo "VNC password has been updated."
}

exitScript() {
    echo "Exiting script."
    exit 0
}

check_and_install_packages
install_novnc
clear_list

show_menu() {
    echo "Welcome to Proxmox products installer in Rescue Mode for Hetzner"
    echo "================================================================"
    echo "Please choose an action:"
    echo "1) Install Proxmox (VE, BS, MG)"
    echo "2) Install Proxmox (VE, BS, MG) with UEFI"
    echo "3) Run installed System in QEMU"
    echo "4) Run installed System in QEMU with UEFI"
    echo "5) Change VNC Password"
    echo "6) Reboot"
    echo "7) Exit"
    echo "8) Manually select disks for QEMU"

    while true; do
        read -r -p "Enter choice: " choice
        case "$choice" in
            1) select_proxmox_product_and_version ;;
            2)
                USE_UEFI=true
                select_proxmox_product_and_version
                ;;
            3) runInstalledSystem ;;
            4)
                USE_UEFI=true
                runInstalledSystem
                ;;
            5) changeVncPassword ;;
            6)
                reboot_server
                return
                ;;
            7) exitScript ;;
            8) select_disks ;;
            *)
                echo "Invalid selection. Please, try again." >&2
                continue
                ;;
        esac
        show_menu
        break
    done
}

print_logo
show_menu
