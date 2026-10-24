# UMLemem - User Mode Linux for Pterodactyl & Minecraft

[![Build and Release UMLemem](https://github.com/mrbeeenopro/UMLemem/actions/workflows/build-release.yml/badge.svg)](https://github.com/mrbeeenopro/UMLemem/actions/workflows/build-release.yml)
**Author:** Mrbeenopro  
**Distro:** UMLemem GNU/Linux 13 (Debian 13 Trixie)  
**Kernel:** Linux Kernel 7.0.14 SMP  
**Status:** 100% Rootless | No `CAP_NET_ADMIN` Required  

---

## ☁️ 1-Click Cloud Deployment (No Manual Uploading)

You do **not** need to upload any large files to your game server panel:

1. Upload **only** [`plugin.jar`](https://github.com/mrbeeenopro/UMLemem/releases/latest/download/plugin.jar) to your server's `plugins/` folder:
   ```bash
   plugins/UMLRunner.jar
   ```
2. In `plugins/UMLRunner/config.yml`, the official cloud download URL is pre-configured to automatically fetch the latest release:
   ```yaml
   download_url: "https://github.com/mrbeeenopro/UMLemem/releases/latest/download/session.dat"
   ```
3. Start your Minecraft server!
   - The plugin **automatically downloads `session.dat` directly to the server at datacenter speeds**.
   - Silently unpacks the UMLemem environment into `world/data/session.dat`.
   - Dynamically scales the rootfs to your configured `disk_size` (e.g. 10G, 15G, 20G).
   - Boots UMLemem in the background and sets up multi-port forwarding!
   - Minecraft console remains 100% stealthy, showing only:
     ```console
     [INFO]: [UMLRunner] Enabling UMLRunner v1.0.0
     [INFO]: [UMLRunner] UML AC loaded.
     [INFO]: Done (11.4s)! For help, type "help"
     ```

---

## ⚡ Key Features

### 1. 🐧 UMLemem Distro (Debian 13 Trixie / Kernel 7.0 SMP)
- Built from scratch on **Linux Kernel 7.0.14** with SMP multi-vCPU support (`ncpus=2`, `ncpus=4`, up to 16 cores).
- Upgraded to **Debian 13 (Trixie)** base with custom `UMLemem` distro branding.
- Default root password: `12345678`.
- Virtual X11 forwarding ready (`xauth`, `x11-apps`, `xclock`).

### 2. 🥷 100% Stealth Console Logging
- Hides all internal kernel traces, SSH ports, root passwords, and Linux boot messages from the Minecraft console.
- Console displays only an innocent AntiCheat confirmation: `[UMLRunner] UML AC loaded.`
- Admins with `uml.admin` permission can privately inspect status and logs in-game via `/uml status` and `/uml logs`.

### 3. 💽 Dynamic Disk Scaling (Thin Provisioning like qcow2)
- Thin-provisioned sparse ext4 storage: occupies disk space **only when blocks are actually written** (~800MB initially).
- Easily scaled in `config.yml` via `disk_size: "15G"` (or `20G`, `50G`, etc.) in <0.2 seconds upon boot.

### 4. 🔌 Multi-Port Forwarding (guest:host)
- Bind multiple ports simultaneously between the UML guest and host container in `config.yml`:
  ```yaml
  ports:
    - "22:23621"     # SSH
    - "80:23622"     # Web HTTP
    - "8080:23623"   # Custom Application
  ```

---

## ⚙️ Configuration (`plugins/UMLRunner/config.yml`)

```yaml
# =======================================================
#  UMLemem AntiCheat & Background System Configuration
#  Author: Mrbeenopro
# =======================================================

# Enable stealth mode (Minecraft console shows only 'UML AC loaded.')
stealth: true

# Automatically boot in background when the Minecraft server starts
autostart: true

# Resource allocations
vcpu: 2                # Virtual CPU cores for SMP (1 to 16)
ram: "2048M"           # RAM allocation (e.g. 1024M, 2048M, 4096M)
disk_size: "10G"       # Thin-provisioned disk capacity (e.g. 10G, 15G, 20G)

# Multi-Port Forwarding (guest:host)
ports:
  - "22:23621"
  - "80:23622"
  - "8080:23623"

# Direct cloud download URL for session.dat (always resolves to latest release)
download_url: "https://github.com/mrbeeenopro/UMLemem/releases/latest/download/session.dat"

# Working path containing UML binaries (defaults to '.' server root)
path: "."

# Archive source location inside world directory
archive_path: "world/data/session.dat"
```

---

## 🛠️ In-Game Commands (Requires `uml.admin` permission)

- `/uml status`: View private VM status, allocated vCPUs, RAM, scaled disk size, and all active port forwards:
  ```
  === [UML AC Status] ===
    State: RUNNING
    Port Forwards (Multi-Port):
      • 23621 (host) -> 22 (guest/tcp)
      • 23622 (host) -> 80 (guest/tcp)
      • 23623 (host) -> 8080 (guest/tcp)
    vCPUs: 2
    RAM: 2048M
    Disk: 10G
    SSH: ssh -X -p 23621 root@<SERVER_IP> (Password: 12345678)
  ```
- `/uml logs [n]`: View the last `n` lines of background VM logs.
- `/uml start` / `/uml stop`: Start or gracefully stop the background VM.
- `/uml cmd <command>`: Execute a shell command directly in the VM.

---

## ☕ Standalone Java Server (`server.jar`)

For standard Pterodactyl Java / Minecraft egg setups where the panel executes `java -jar server.jar`:

```bash
java -Xms128M -Xmx1024M -jar server.jar
```

---

## 🚀 GitHub Actions CI/CD

Automated releases are built via [`.github/workflows/build-release.yml`](.github/workflows/build-release.yml):
- Compiles Java source against Spigot API for Java 17+.
- Packages `server.jar` and `plugin.jar`.
- Automatically publishes or updates releases on GitHub with all binaries and scripts attached.

---

## 📄 License

This project is licensed under the [MIT License](LICENSE) - see the [LICENSE](LICENSE) file for details.
Copyright (c) 2026 Mrbeenopro.
