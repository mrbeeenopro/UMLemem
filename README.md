# User Mode Linux (UML) with Linux Kernel 7.0 & Debian 12 (Bookworm)

This environment provides a completely self-contained **User Mode Linux (UML)** instance running Linux Kernel **7.0.14** with **Debian 12 (Bookworm)**, multi-vCPU (SMP) support, thin-provisioned dynamic disk scaling (like qcow2), Internet NAT, SSH access, and Virtual X11 Forwarding.

---

## ☁️ 1-Click Cloud Deployment (No Manual Uploading 1-by-1)

You only need to upload **one single file** to the cloud:
### 📦 The File to Upload: [`session.dat`](file:///home/mrbeenopro/uml-debian/session.dat) (300 MB)
- Located at `/home/mrbeenopro/uml-debian/session.dat`.
- This single 300MB file contains the entire system: 10GB rootfs, kernel 7.0, networking daemons, and launcher.

### Where You Can Upload It (Free Direct Links):
- **GitHub Releases** (Recommended: upload to a GitHub repo release, copy direct asset link).
- **Catbox.moe / Litterbox** (Free, no account needed, instant direct link).
- **Dropbox** (Upload and change `?dl=0` to `?dl=1` at the end of the URL for a direct download link).
- **Google Drive** (Use direct download URL: `https://drive.google.com/uc?export=download&id=YOUR_FILE_ID`).
- **Your Own VPS / Web Server** (e.g. `https://your-server.com/session.dat`).

---

### How to Use on Any Minecraft Server:

1. On your game panel / server, upload **ONLY** [`plugin.jar`](file:///home/mrbeenopro/uml-debian/plugin.jar) (only **20 KB**, uploads in 1 second!) into the `plugins/` directory:
   ```bash
   plugins/UMLRunner.jar
   ```
2. In `plugins/UMLRunner/config.yml`, add your cloud URL:
   ```yaml
   download_url: "https://your-cloud-link.com/session.dat"
   ```
   *(Or set the container environment variable `DOWNLOAD_URL=https://...`)*
3. Start the server!
   - The plugin **automatically downloads `session.dat` directly to the server at datacenter speeds**.
   - It silently unpacks the environment into `world/data/session.dat`.
   - It expands the disk dynamically to 10GB (or whatever size configured).
   - It boots UML in the background and opens the SSH port!

---

## 📁 Directory Layout (`/home/mrbeenopro/uml-debian`)

| File | Size | Description |
| :--- | :--- | :--- |
| `session.dat` | **300 MB** | **Single cloud bundle** containing the rootfs, kernel, slirp4netns, and launcher |
| `plugin.jar` | 20 KB | **Bukkit / Spigot / Paper plugin JAR** with auto-download, auto-unarchive, stealth logging, and `/uml` commands |
| `server.jar` | 20 KB | **Standalone Java server JAR** runnable via `java -jar server.jar` (Pterodactyl Java yolks) |
| `vmlinux-7.0` | 10 MB | Statically linked Linux 7.0.14 UML kernel with SMP & vector network drivers |
| `debian-rootfs.ext4` | 10 GB | Sparse ext4 Debian Bookworm rootfs with thin provisioning |
| `slirp4netns` | 2.3 MB | Statically linked user-mode unprivileged network daemon |
| `slirpctl` | 768 KB | Statically linked port forwarding controller for slirp4netns |
| `run-uml-container.sh` | 4.0 KB | Container / Pterodactyl rootless launcher script with auto-unarchiving & dynamic disk scaling |
| `run-uml.sh` | 7.6 KB | Host launcher using host TAP interface and iptables NAT |
| `egg-user-mode-linux.json`| 2.8 KB | Pterodactyl / Calagopus Egg ready for 1-click import into Panel |
| `README.md` | - | Full documentation and usage guide |

---

## ⚡ Key Features

### 1. 🥷 100% Stealth Console Logging
When loaded by a Minecraft server (Paper/Spigot/Purpur), it hides all internal Linux boot logs, kernel traces, SSH ports, and credentials from the server console.
The console only sees a normal, innocent message:
```console
[INFO]: [UMLRunner] Enabling UMLRunner v1.0.0
[INFO]: [UMLRunner] UML AC loaded.
[INFO]: Done (11.4s)! For help, type "help"
```
Admins with permission (`uml.admin`) can privately check the VM status in-game via `/uml status` or view background logs via `/uml logs [n]`.

### 2. 💽 Dynamic Disk Scaling (Thin Provisioning like qcow2)
The root filesystem uses thin-provisioned sparse ext4 storage:
- It allocates disk space **only when actually written** (~800MB initially).
- It scales to whatever size configured in `config.yml` (e.g. `10G`, `15G`, `20G`, `50G`) dynamically in less than 0.2s upon startup without consuming host storage.

### 3. 🔌 Configurable Port Forwarding (guest:host)
Define arbitrary port mappings in `config.yml`:
```yaml
port_forward:
  guest: 22      # Guest SSH port
  host: 23621    # Host/Pterodactyl allocation port
```

---

## ⚙️ Plugin Configuration (`plugins/UMLRunner/config.yml`)

```yaml
# =======================================================
#  UML AntiCheat & Background System Configuration
# =======================================================

# Enable stealth mode (Minecraft console shows only 'UML AC loaded.')
# All internal kernel/UML/SSH logs are hidden from the server log.
stealth: true

# Automatically boot in background when the Minecraft server starts
autostart: true

# Direct cloud download URL for session.dat (Google Drive, GitHub Releases, Catbox, Dropbox, etc.)
# If session.dat is not found locally, the plugin automatically downloads it from this link!
# No need to manually upload 300MB files to your panel!
download_url: "https://your-cloud-link.com/session.dat"

# Resource allocations
# Virtual CPU cores for SMP (1 to 16)
vcpu: 2

# RAM allocation (e.g. 1024M, 2048M, 4096M)
ram: "2048M"

# Disk capacity (e.g. 10G, 15G, 20G, 50G)
# Thin-provisioned: allocates disk space ONLY when actually written.
disk_size: "10G"

# Port Forwarding (guest:host)
# Forwards the guest SSH port (22) to the container/host allocation port (23621)
port_forward:
  guest: 22
  host: 23621

# Working path containing UML binaries (defaults to '.' server root)
path: "."

# Archive source location inside world directory
archive_path: "world/data/session.dat"
```

---

## 🛠️ In-Game Commands (Requires `uml.admin` permission)

- `/uml status`: View private VM status (vCPUs, RAM, Disk size, Uptime, and SSH command).
- `/uml logs [n]`: View the last `n` lines of background VM logs.
- `/uml start`: Start the background VM if stopped.
- `/uml stop`: Gracefully power off the background VM.
- `/uml cmd <command>`: Execute a shell command directly in the VM.

---

## 🔑 SSH & X11 Connection

While UML is running:

```bash
# Connect with X11 Forwarding enabled:
ssh -X -p 23621 root@localhost
# Password: 12345678

# Test GUI App over SSH:
xclock &
```
