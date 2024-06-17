# ProxRescue
Proxmox Products Installer in Rescue Mode for Hetzner


Description

This script is designed to install Proxmox products (Proxmox Virtual Environment, Proxmox Backup Server, Proxmox Mail Gateway) in rescue mode on Hetzner servers. It allows you to select the product to install, configure VNC connection settings, and use UEFI if needed. Additionally, the script can launch the installed Proxmox system, allowing you to connect via VNC or noVNC.


Requirements

Before running the script, ensure that your system has the following packages installed:

    curl
    sshpass
    git

Installation of Required Packages

If the required packages are not installed, the script will attempt to install them automatically.
Usage

Run the script with the appropriate parameters to install the selected Proxmox product or to configure the system:
Command Line Parameters

    -ve: Install Proxmox Virtual Environment.
    -bs: Install Proxmox Backup Server.
    -mg: Install Proxmox Mail Gateway.
    -vport: Set the port for noVNC (default 8080).
    -p, --password PASSWORD: Specify a password for the VNC connection.
    -uefi: Use UEFI for installation or system run.
    -h, --help: Show this help message and exit.

Examples

    Install Proxmox Virtual Environment with a specified VNC password:    

       ./ProxRescue.sh -ve -p yourVNCpassword

    Install Proxmox Backup Server using UEFI and specifying the port for noVNC:

       ./ProxRescue.sh -bs -uefi -vport 8081

    Run the installed system in UEFI mode:

       ./ProxRescue.sh -run -uefi

Main Menu

When running the script without parameters, the main menu will be displayed:

    1. Install Proxmox (VE, BS, MG)
    2. Install Proxmox (VE, BS, MG) with UEFI
    3. Run installed System in QEMU
    4. Run installed System in QEMU with UEFI
    5. Change VNC Password
    6. Reboot
    7. Exit

Features

    Automatic Installation of Proxmox Products:
        Choose from Proxmox Virtual Environment, Proxmox Backup Server, or Proxmox Mail Gateway.
        Automatically download the latest version of the selected product.

    VNC Configuration:
        Set a custom VNC password for secure access.
        Specify the noVNC port to avoid conflicts with existing services.

    UEFI Support:
        Optionally use UEFI for installation and running the system.
        Automatically configure UEFI boot settings.

    Network Configuration:
        Automatically detect and configure network settings.
        Provide root password to set up network configuration in the installed Proxmox system.

    Reboot Management:
        Option to reboot the server after installation or configuration changes.
        Ensure clean shutdown of all running services before rebooting.

    NoVNC Integration:
        Automatically set up and run noVNC for web-based VNC access.
        Cleanly stop noVNC sessions when no longer needed.

    Interactive Menu:
        User-friendly menu interface for selecting installation and configuration options.
        Ability to run the script non-interactively with command-line parameters.

Notes

    The script automatically clears the SSH key cache for localhost on port 2222.
    The script automatically terminates all noVNC sessions before starting a new one.

MIT License

Copyright (c) 2024 Proxmox UA

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE. 

Communities and Support

    Telegram: Proxmox_UA
    GitHub: https://github.com/Proxmoxinfo/ProxMoxRescueHelper
    Website: proxmox.info

This script is designed for installing Proxmox products in rescue mode on Hetzner servers.