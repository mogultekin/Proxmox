# Proxmox Interactive Backup Tool

An **interactive backup utility for Proxmox VE** that simplifies running `vzdump` backups from the terminal with a clean TUI interface.

The tool allows you to select backup storage, mode, and guests interactively while showing live progress for both **VMs and LXC containers**.

It is designed to behave similarly to **Proxmox CLI tools and Proxmox Helper Scripts**.

---

# Features

- Interactive **TUI interface (whiptail)**
- Backup **VMs and LXC containers**
- **Sequential or Parallel** execution
- Live **progress bars for VMs**
- **Spinner indicator** for LXC backups
- Select **backup storage**
- Select **backup mode**
  - Snapshot
  - Suspend
  - Stop
- **Skip stopped guests**
- Select **guests to skip**
- Automatic **backup pruning**
- **Protection window**
  - backups newer than **2 hours are never deleted**
- Writes **backup method into notes**
- Clean terminal output
- Safe **Ctrl+C handling**

---

# Installation

Run directly from GitHub:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mogultekin/Proxmox/main/tools/backup-proxmox.sh)"
```

Or install manually:

```bash
wget https://raw.githubusercontent.com/mogultekin/Proxmox/main/tools/backup-proxmox.sh
chmod +x backup-proxmox.sh
./backup-proxmox.sh
```

---

# Requirements

The script runs on a standard **Proxmox VE host**.

Required tools:

```text
whiptail
qm
pct
vzdump
pvesm
stdbuf
```

All of these are included by default in **Proxmox VE installations**.

---

# Example Output

```text
Storage: VMBackup
Mode: snapshot
Execution: sequential

Starting snapshot backup of VM:108-VM8
108    ████████████████ 100% done
Backup complete: 108

Starting snapshot backup of CT:209-CT9
209    ████████████████ 100% done
Backup complete: 209

All backups completed.
```

---

# Backup Workflow

The tool guides you through the backup process:

1. Select **execution mode**
2. Select **backup storage**
3. Select **backup method**
4. Choose whether to **skip stopped guests**
5. Select **guests to skip**
6. Start backups with **live progress**

---

# Backup Retention

After a successful backup:

- The **newest backup is always kept**
- Older backups are automatically removed
- Backups **newer than 2 hours are protected**

Example:

```text
Backup complete: 108
Removed vzdump-qemu-108-2026_03_09-08_59_18
Removed vzdump-qemu-108-2026_03_08-08_59_12
```

---

# Backup Notes

Each backup writes metadata into the **Proxmox Notes field**.

Example:

```text
108-VM8@proxmox-snapshot
```

Format:

```text
VMID-GuestName@Node-BackupMode
```

---

# Parallel Execution

Parallel mode allows multiple backups to run simultaneously.

Default limit:

```text
3 concurrent backups
```

This helps avoid excessive disk or CPU load.

---

# Interrupt Handling

Pressing:

```text
Ctrl+C
```

will safely stop the script and restore the terminal state.

---

# Supported Storage

Works with any Proxmox storage configured for **backup content**:

- Directory storage
- NFS
- CIFS
- ZFS directories
- Proxmox Backup Server

---

# Repository Structure

```text
Proxmox/
 ├─ tools/
 │   └─ backup-proxmox.sh
 └─ README.md
```

---

# License

MIT License
