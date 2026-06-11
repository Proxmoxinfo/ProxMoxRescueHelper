# ProxRescue

English | [Русский](README_RU.md) | [Українська](README_UK.md)

**A one-file script that installs Proxmox on a Hetzner dedicated server, straight from the rescue system.**

If you've ever tried to install Proxmox VE/PBS/PMG/PDM on a Hetzner box, you know the drill: boot into rescue mode, fight with QEMU just to get a graphical installer running, set up VNC/noVNC access yourself, then manually fix up the network, repos and subscription nag afterwards. ProxRescue takes care of all the surrounding work — it boots the official Proxmox ISO in QEMU and gives you a noVNC link, you go through the actual Proxmox installer yourself (partitioning, passwords, etc.) like you normally would, and then the script automatically configures networking and applies the post-install tweaks for you.

So it's not a fully unattended/zero-click installer — you still click through the Proxmox installer in your browser — but it removes all the tedious setup and cleanup around it.

## What it does

- Boots the official Proxmox installer ISO inside QEMU and gives you a noVNC link so you can run through the installer in your browser as usual.
- Picks the right boot mode (UEFI or Legacy BIOS) automatically based on your rescue system's firmware.
- Once you've finished the installer, it sets up networking on the freshly installed system (bridge `vmbr0`, correct IP/gateway) so it boots straight onto the network.
- Optionally applies the usual post-install tweaks: switch to no-subscription repos, remove the subscription nag, fix Debian sources, run a full upgrade, disable HA on single-node setups.
- Can also boot an already-installed system back up in QEMU if you need to get back in.

## Quick Start

ProxRescue is a single self-contained script — no repo to clone, just one file.

Run it directly in the Hetzner rescue system:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh)"
```

Want to pass flags with the one-liner? Add `_` as a placeholder for `$0`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh)" _ -pve -auto -dns 8.8.8.8
```

Or grab the script once and run it whenever you like:

```bash
curl -fsSL -o ProxRescue.sh https://raw.githubusercontent.com/Proxmoxinfo/ProxMoxRescueHelper/refs/heads/main/ProxRescue.sh && chmod +x ProxRescue.sh
./ProxRescue.sh -pve -auto -dns 8.8.8.8
```

## Requirements

You'll need these packages on the rescue system:

- `curl`
- `sshpass`
- `dialog`
- `git`

Don't worry if they're missing — the script will install them for you.

## Usage

Run the script with no arguments to get an interactive menu, or pass flags to skip straight to an installation.

### Installation

| Flag | What it installs |
| --- | --- |
| `-pve` | Proxmox Virtual Environment |
| `-pbs` | Proxmox Backup Server |
| `-pmg` | Proxmox Mail Gateway |
| `-pdm` | Proxmox Datacenter Manager |

### Post-install tweaks

| Flag | What it does |
| --- | --- |
| `-fix-sources` | Fix Debian's base sources to point at deb.debian.org |
| `-no-sub` | Switch Enterprise repos to no-subscription and remove the subscription nag |
| `-upgrade` | Run `apt update && apt dist-upgrade` (requires `-no-sub`) |
| `-disable-ha` | Disable HA services (single-node PVE only) |
| `-auto` | Apply everything above without asking |

If you don't pass these flags, the script will ask you after installation whether to apply each one.

### Connection & misc

| Flag | What it does |
| --- | --- |
| `-p`, `--password PASSWORD` | Set the VNC password |
| `-vport PORT` | Set the noVNC port (default `8080`) |
| `-dns DNS_SERVER[,DNS_SERVER...]` | Set one or more DNS servers, comma-separated (default: auto-detected from the rescue system, falling back to `1.1.1.1`) |
| `-uefi` / `-legacy` | Force a boot mode instead of auto-detecting it |
| `-h`, `--help` | Show the help message |

If you don't pass `-uefi` or `-legacy`, ProxRescue figures out the boot mode from the rescue system's firmware. Same goes for DNS — if you don't set `-dns`, it reads `/etc/resolv.conf` and uses whatever it finds (falling back to `1.1.1.1` if nothing usable is there).

## Examples

Install Proxmox VE and set a VNC password:

```bash
./ProxRescue.sh -pve -p yourVNCpassword
```

Install Proxmox VE, apply all post-install tweaks, and use a custom DNS server:

```bash
./ProxRescue.sh -pve -auto -dns 8.8.8.8
```

Install Proxmox Backup Server, switch to no-subscription repos and upgrade:

```bash
./ProxRescue.sh -pbs -no-sub -upgrade
```

Install Proxmox VE with a custom set of post-install fixes:

```bash
./ProxRescue.sh -pve -fix-sources -no-sub -upgrade -disable-ha
```

## Main Menu

Run the script without any flags and you'll get this menu:

```
1) Select disks for QEMU
2) Install Proxmox (PVE, PBS, PMG, PDM)
3) Run installed System in QEMU
4) Toggle boot mode (current: ...)
5) Change VNC Password
6) Change DNS server(s)
7) Reboot
8) Exit
```

The current boot mode is shown right at the top.

## Features

**Self-update** — the script checks GitHub for a newer version on startup and offers to update itself in place, restarting with the same arguments you passed.

**Automatic ISO download** — pick a product and it grabs the latest ISO straight from download.proxmox.com, verifies the SHA256 checksum, and boots it in QEMU. You can also pick an older version from the list if you need to. The actual installation (partitioning, passwords, etc.) is still done by you through noVNC, just like a normal Proxmox install.

**Post-install optimizations** — fix Debian's sources, switch to no-subscription repos and strip the subscription nag from both the web and mobile UI, run a full `apt upgrade`, and disable HA services on single-node setups. Apply them one at a time, or all together with `-auto`.

**VNC & noVNC** — a random VNC password is generated for you (or set your own), and noVNC gives you browser-based access — just open `http://<server-ip>:8080`.

**Boot mode handling** — auto-detects UEFI vs Legacy BIOS from the rescue system, or force it with `-uefi`/`-legacy`.

**DNS configuration** — auto-detects all DNS servers from the rescue system (correctly handling the systemd-resolved stub resolver at 127.0.0.53), or override with `-dns 8.8.8.8,1.1.1.1`. Whatever is detected/configured gets written to `/etc/resolv.conf` on the installed system.

**Networking** — after installation, the script configures `vmbr0` with the server's real IP and gateway so the system comes up on the network ready to go. You'll just need to enter the root password you set during installation so it can connect over SSH and apply the config.

**Reboot management** — reboot cleanly from the menu; QEMU and noVNC are shut down properly first.

**Disk selection** — by default all disks are passed to QEMU, but you can pick specific ones from the menu.

## A few things to keep in mind

- The script terminates any running noVNC sessions and sends `quit` to the QEMU monitor whenever it starts or exits.
- KVM (`/dev/kvm`) is required and gets checked at startup.
- **While the Proxmox installer is running (inside noVNC/VNC), don't touch the network/IP settings** — leave them on the defaults. ProxRescue configures the network for you afterwards, and changing the IP manually during installation will break the automatic network setup and the post-install tweaks.

## Acknowledgements

Some of the post-install logic (repo switching and subscription nag removal) is adapted from [community-scripts.org](https://community-scripts.org).

## License

MIT — see below.

```
Copyright (c) 2026 Proxmox UA

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
```

## Community & Support

- Telegram: [Proxmox_UA](https://t.me/Proxmox_UA)
- GitHub: [Proxmoxinfo/ProxMoxRescueHelper](https://github.com/Proxmoxinfo/ProxMoxRescueHelper)
- Website: [proxmox.info](https://proxmox.info)
