#!/bin/bash

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

VERSION_SCRIPT="0.6"
SCRIPT_TYPE="self-contained"

logo='
██████  ██████   ██████  ██   ██ ███    ███  ██████  ██   ██    ██ ███    ██ ███████  ██████  
██   ██ ██   ██ ██    ██  ██ ██  ████  ████ ██    ██  ██ ██     ██ ████   ██ ██      ██    ██ 
██████  ██████  ██    ██   ███   ██ ████ ██ ██    ██   ███      ██ ██ ██  ██ █████   ██    ██ 
██      ██   ██ ██    ██  ██ ██  ██  ██  ██ ██    ██  ██ ██     ██ ██  ██ ██ ██      ██    ██ 
██      ██   ██  ██████  ██   ██ ██      ██  ██████  ██   ██ ██ ██ ██   ████ ██       ██████  
'

VNC_PASSWORD=""
PRODUCT_CHOICE=""
NOVNC_PORT=""
USE_UEFI=""
NAME_SERVER="1.1.1.1"

QEMU_MEMORY="3000"	# in megabytes

if [ -z "$VNC_PASSWORD" ]; then    
    VNC_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8)    
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
    echo "  -uefi                     Use UEFI for installation or system run."
    echo "  -h, --help                Show this help message and exit."
    echo ""
    echo "Example:"
    echo "  $0 -ve -p yourVNCpassword   Install Proxmox VE with a specified VNC password."
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--password)
            VNC_PASSWORD="$2"
            shift 
            shift 
            ;;
        -vport)
            NOVNC_PORT="$2"
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
        -uefi)
            USE_UEFI="true"
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;    
        *)
            shift 
            ;;
    esac
done

clear_list() {    
    pkill -f websockify
    echo "All noVNC sessions have been terminated."
    ssh-keygen -R 127.0.0.1:2222
    echo "SSH key cache cleared for 127.0.0.1 port 2222."
    printf "quit\n" | nc 127.0.0.1 4444
    echo "Sent shutdown command to QEMU."
}

print_logo() {
    clear
    echo "$logo"        
}

get_network_info() {
    INTERFACE_NAME=$(udevadm info -q property /sys/class/net/$(ls /sys/class/net | grep -E '^(eth|ens|enp)') | grep "ID_NET_NAME_PATH=" | cut -d'=' -f2)
    if [ -z "$INTERFACE_NAME" ]; then
        echo "No valid network interface found."
        exit 1
    fi

    IP_CIDR=$(ip addr show $INTERFACE_NAME | grep "inet\b" | awk '{print $2}')
    GATEWAY=$(ip route | grep default | awk '{print $3}')
    IP_ADDRESS=$(echo "$IP_CIDR" | cut -d'/' -f1)
    CIDR=$(echo "$IP_CIDR" | cut -d'/' -f2)
}


check_and_install_packages() {
    local required_packages=(curl sshpass)
    local missing_packages=()
    for package in "${required_packages[@]}"; do
        if ! dpkg -l | grep -qw $package; then
            missing_packages+=("$package")
        fi
    done
    if [ ${#missing_packages[@]} -eq 0 ]; then
        clear
        echo "$logo"
    else
        echo "Installing required packages..."
        apt update -qq
        for package in "${missing_packages[@]}"; do
            echo "Install package: $package"
            apt install -y $package -qq
        done
        clear
        echo "$logo"
    fi
}

install_novnc() {
    echo "Checking for noVNC installation..."
    if [ ! -d "noVNC" ]; then
        echo "noVNC not found. Cloning noVNC from GitHub..."
        git clone https://github.com/novnc/noVNC.git
        echo "Cloning websockify for noVNC..."
        git clone https://github.com/novnc/websockify noVNC/utils/websockify        
        echo "Renaming vnc.html to index.html..."
        cp noVNC/vnc.html noVNC/index.html        
    else
        echo "noVNC is already installed."        
        if [ ! -f "noVNC/index.html" ]; then
            echo "Renaming vnc.html to index.html..."
            cp noVNC/vnc.html noVNC/index.html
        elif [ ! -f "noVNC/vnc.html" ]; then
            echo "Warning: vnc.html does not exist. Please check your noVNC installation."
        fi
    fi
}

configure_network() {
    get_network_info
    cat > /tmp/proxmox_network_config <<EOF
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
        read -s -p "To configure the network on your server, enter the root password you set when installing $PRODUCT_NAME: " ROOT_PASSWORD
        sshpass -p "$ROOT_PASSWORD" scp -o StrictHostKeyChecking=no -P 2222 /tmp/proxmox_network_config root@127.0.0.1:/etc/network/interfaces
        if [ $? -eq 5 ]; then
            echo "Authorization error. Please check your root password."
        else
            break 
        fi
    done
    sshpass -p "$ROOT_PASSWORD" ssh -o StrictHostKeyChecking=no -p 2222 root@127.0.0.1 "sed -i 's/nameserver.*/nameserver $NAME_SERVER/' /etc/resolv.conf"
    if [ $? -ne 0 ]; then
        echo "Error in change resolv.conf."
    else
        echo "resolv.conf updated."
        echo "Shutdown QEMU"
        printf "system_powerdown\n" | nc 127.0.0.1 4444
        reboot_server
    fi
}

select_disks() {
    echo "Available disks:"
    lsblk -dn -o NAME,TYPE,SIZE | awk '$2 == "disk" {print NR ": " $1 " (" $3 ")"}'
    echo "Please enter the numbers of the disks you want to use, separated by spaces:"
    read -r selected_disks

    QEMU_DISK_ARGS=""
    for disk_number in $selected_disks; do
        disk_name=$(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" {print $1}' | sed -n "${disk_number}p")
        if [ -n "$disk_name" ]; then
            QEMU_DISK_ARGS="$QEMU_DISK_ARGS -drive file=/dev/$disk_name,format=raw,if=virtio,media=disk"
        else
            echo "Invalid disk number: $disk_number"
        fi
    done

    if [ -z "$QEMU_DISK_ARGS" ]; then
        echo "No valid disks selected. Exiting."
        exit 1
    fi
}



run_qemu() {
    get_network_info
    local task=$1
    if [ -z "$QEMU_DISK_ARGS" ]; then
        DISKS=$(lsblk -dn -o NAME,TYPE -e 1,7,11,14,15 | awk '$2 == "disk" {print $1}')
        DISK_INDEX=0
        for DISK in $DISKS; do
            QEMU_DISK_ARGS="$QEMU_DISK_ARGS -drive file=/dev/$DISK,format=raw,if=virtio,index=$DISK_INDEX,media=disk"
            DISK_INDEX=$((DISK_INDEX+1))
        done
    fi

    QEMU_COMMON_ARGS="-daemonize -enable-kvm -m $QEMU_MEMORY -vnc :0,password=on -monitor telnet:127.0.0.1:4444,server,nowait"
    if [ "$USE_UEFI" == "true" ]; then
        QEMU_COMMON_ARGS="-bios /usr/share/ovmf/OVMF.fd $QEMU_COMMON_ARGS"
    fi
    if [ "$task" == "install" ]; then
        QEMU_CDROM_ARGS="-drive file=/tmp/proxmox.iso,index=0,media=cdrom -boot d"
        qemu-system-x86_64 $QEMU_COMMON_ARGS $QEMU_DISK_ARGS $QEMU_CDROM_ARGS
        echo -e "\nQemu running...."
        sleep 2
        echo "change vnc password $VNC_PASSWORD" | nc -q 1 127.0.0.1 4444
        print_logo
        echo "Use VNC client or Use Web Browser for connect to your server."
        echo -e "Ip for vnc connect:  $IP_ADDRESS\n"
        echo "For use NoVNC open in browser http://$IP_ADDRESS:$NOVNC_PORT"
        echo -e "\nYou password for connect: \033[1m$VNC_PASSWORD\033[0m\n" # Выделение пароля
        ./noVNC/utils/novnc_proxy --vnc 127.0.0.1:5900 --listen $IP_ADDRESS:$NOVNC_PORT > /dev/null 2>&1 &
        NOVNC_PID=$!
        while true; do
            if ! pgrep -f "qemu-system-x86_64" > /dev/null; then
                echo "QEMU process has stopped unexpectedly."
                kill $NOVNC_PID 2>/dev/null
                echo "noVNC stopped."
                reboot_server
                break
            fi
            echo -ne "Installation in progress... If installation is complete, enter \"yes\" to continue: \r"
            read -t 5 -n 3 confirmation
            if [[ "$confirmation" == "yes" ]]; then
                echo "QEMU shutting down...."
                printf "quit\n" | nc 127.0.0.1 4444
                kill $NOVNC_PID  # завершение novnc_proxy
                echo "noVNC stopped."
                print_logo
                configure_network
                break
            fi
        done
    elif [ "$task" == "settings" ]; then
        QEMU_NETWORK_SETTINGS="-net user,hostfwd=tcp::2222-:22 -net nic"
        qemu-system-x86_64 $QEMU_COMMON_ARGS $QEMU_DISK_ARGS $QEMU_NETWORK_SETTINGS
    elif [ "$task" == "runsystem" ]; then
        qemu-system-x86_64 $QEMU_COMMON_ARGS $QEMU_DISK_ARGS &
        QEMU_PID=$!
        echo -e "\nQemu running...."
        sleep 2
        echo "change vnc password $VNC_PASSWORD" | nc -q 1 127.0.0.1 4444
        print_logo
        echo "Use VNC client or Use Web Browser for connect to your server."
        echo -e "Ip for vnc connect:  $IP_ADDRESS\n"
        echo "For use NoVNC open in browser http://$IP_ADDRESS:$NOVNC_PORT"
        echo -e "\nYou password for connect: \033[1m$VNC_PASSWORD\033[0m\n" # Выделение пароля
        ./noVNC/utils/novnc_proxy --vnc 127.0.0.1:5900 --listen $IP_ADDRESS:$NOVNC_PORT > /dev/null 2>&1 &
        NOVNC_PID=$!
        while true; do
            if ! pgrep -f "qemu-system-x86_64" > /dev/null; then
                echo "QEMU process has stopped unexpectedly."
                kill $NOVNC_PID 2>/dev/null
                echo "noVNC stopped."
                reboot_server
                break
            fi
            echo -ne "System running... Enter 'shutdown' to shut down QEMU: \r"
            read -t 5 -n 8 confirmation
            if [[ "$confirmation" == "shutdown" ]]; then
                echo "QEMU shutting down manually..."
                printf "system_powerdown\n" | nc 127.0.0.1 4444
                kill $NOVNC_PID 2>/dev/null
                echo "noVNC stopped."
                reboot_server
                break
            fi
        done
    fi   
}


select_proxmox_product_and_version() {
    if [ -n "$PRODUCT_CHOICE" ]; then
        echo "Product has been already selected: $PRODUCT_CHOICE"

        case $PRODUCT_CHOICE in
            "Proxmox Virtual Environment")
                GREP_PATTERN='proxmox-ve_(\d+.\d+-\d).iso'
                PRODUCT_NAME="Proxmox Virtual Environment"
                ;;
            "Proxmox Backup Server")
                GREP_PATTERN='proxmox-backup-server_(\d+.\d+-\d).iso'
                PRODUCT_NAME="Proxmox Backup Server"
                ;;
            "Proxmox Mail Gateway")
                GREP_PATTERN='proxmox-mail-gateway_(\d+.\d+-\d).iso'
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
            read -p "Enter number (1-4): " product_choice

            case $product_choice in
                1) GREP_PATTERN='proxmox-ve_([0-9]+.[0-9]+-[0-9]+).iso'; PRODUCT_NAME="Proxmox Virtual Environment"; valid_choice=1 ;;
                2) GREP_PATTERN='proxmox-backup-server_([0-9]+.[0-9]+-[0-9]+).iso'; PRODUCT_NAME="Proxmox Backup Server"; valid_choice=1 ;;
                3) GREP_PATTERN='proxmox-mail-gateway_([0-9]+.[0-9]+-[0-9]+).iso'; PRODUCT_NAME="Proxmox Mail Gateway"; valid_choice=1 ;;
                4) echo "Returning to main menu..."; return ;;
                *) echo "Invalid selection. Please, try again."; ;;
            esac
        done
    fi

    print_logo
    echo "Retrieving available versions for $PRODUCT_NAME..."
    AVAILABLE_ISOS=$(curl -s 'http://download.proxmox.com/iso/' | grep -oP "$GREP_PATTERN" | sort -V | tac | uniq)
    IFS=$'\n' read -r -d '' -a iso_array <<< "$AVAILABLE_ISOS"
    echo "Please select the version to install (default is the latest version):"
    for i in "${!iso_array[@]}"; do
        echo "$((i+1))) ${iso_array[i]}"
    done
    echo "$(( ${#iso_array[@]} + 1 )) Return to product selection"
    echo "$(( ${#iso_array[@]} + 2 )) Return to main menu"

    read -t 30 -p "Enter number (1-$((${#iso_array[@]} + 2))) or wait for auto-selection: " version_choice
    if [ -z "$version_choice" ]; then
        version_choice=1
        echo "Auto-selected the latest version due to timeout."
    fi

    if [ "$version_choice" -eq "$(( ${#iso_array[@]} + 1 ))" ]; then
        echo "Returning to product selection..."
        select_proxmox_product_and_version
        return
    elif [ "$version_choice" -eq "$(( ${#iso_array[@]} + 2 ))" ]; then
        echo "Returning to main menu..."
        return
    elif [[ "$version_choice" =~ ^[0-9]+$ ]] && [ "$version_choice" -ge 1 ] && [ "$version_choice" -le "${#iso_array[@]}" ]; then
        selected_iso="${iso_array[$((version_choice-1))]}"
        ISO_URL="http://download.proxmox.com/iso/$selected_iso"
        echo "Downloading $ISO_URL..."
        curl $ISO_URL -o /tmp/proxmox.iso --progress-bar
    else
        echo "Invalid selection, using the latest version."
        selected_iso="${iso_array[0]}"
        ISO_URL="http://download.proxmox.com/iso/$selected_iso"
        echo "Downloading $ISO_URL..."
        curl $ISO_URL -o /tmp/proxmox.iso --progress-bar
    fi
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
    read VNC_PASSWORD
    echo "VNC password set to $VNC_PASSWORD"
}

exitScript() {
    echo "Exiting script."
    exit 0
}

check_and_install_packages
install_novnc
clear_list

declare -A options=(
    [1]="Install Proxmox (VE, BS, MG)"
    [2]="Install Proxmox (VE, BS, MG) with UEFI"
    [3]="Run installed System in QEMU"
    [4]="Run installed System in QEMU with UEFI"
    [5]="Change VNC Password"
    [6]="Reboot"
    [7]="Exit"
    [8]="Manually select disks for QEMU"
)

declare -A actions=(
    [1]="select_proxmox_product_and_version"
    [2]="USE_UEFI=true; select_proxmox_product_and_version"
    [3]="runInstalledSystem"
    [4]="USE_UEFI=true; runInstalledSystem"
    [5]="changeVncPassword"
    [6]="reboot_server"
    [7]="exitScript"
    [8]="select_disks"
)

ordered_keys=("1" "2" "3" "4" "5" "6" "7" "8")



show_menu() {
    echo "Welcome to Proxmox products installer in Rescue Mode for Hetzner" 
    echo "================================================================"
    echo "Please choose an action:"
    for key in "${ordered_keys[@]}"; do
        echo "$key) ${options[$key]}"
    done

    while true; do
        read -p "Enter choice: " choice
        action=${actions[$choice]}
        if [[ -n "$action" ]]; then
            eval $action
            if [[ "$choice" != "6" && "$choice" != "7" ]]; then
                show_menu
            fi
            break
        else
            echo "Invalid selection. Please, try again."
        fi
    done
}

print_logo
show_menu
