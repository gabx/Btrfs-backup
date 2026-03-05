# Btrfs Backup & Snapshot Boot Suite — Arch Linux

A production-grade setup combining bootable btrfs snapshots with incremental off-site backup on Arch Linux. The goal is simple: never lose data, and always be able to roll back the system to a known good state — even if the latest update breaks everything.

This repository documents the full setup as running on **magnolia**, an Arch Linux machine with the COSMIC desktop, homectl-managed users, and a btrfs filesystem.

---

## Why This Setup?

Most backup solutions treat the system and user data separately, and most snapshot tools don't integrate with the bootloader. This setup bridges both:

- **Snapper** takes automatic hourly snapshots of the root filesystem
- **Limine** lists those snapshots in the boot menu — you can boot directly into any of them without mounting anything manually
- **btrfs send/receive** replicates snapshots incrementally to an external drive — only the diff is transferred after the first full send, keeping backup time and disk usage low
- **Email notifications** confirm every backup run, whether it succeeded or failed

The result is a system where a bad `pacman -Syu` can be undone in under a minute, and where `/home` and `/development` are protected against disk failure with weekly off-site backups.

---

## System Configuration

| Element | Value |
|---|---|
| OS | Arch Linux |
| Desktop | COSMIC |
| Bootloader | Limine (UEFI) |
| Filesystem | btrfs (LABEL=Magnolia) |
| Snapshot tool | Snapper |
| Backup destination | `/dev/sda1` mounted on `/backup` |
| User management | homectl |

### btrfs Subvolume Layout

A clean subvolume layout is essential — it determines what Snapper snapshots and what gets excluded. Separating `/var/log`, `/var/cache/pacman/pkg` and `/home` from `@` means snapshots of root stay lean and don't include volatile or user data.

| Subvolume | Mount point |
|---|---|
| `@` | `/` |
| `@home` | `/home` |
| `@home/gabx.homedir` | `/home/gabx` (homectl) |
| `@log` | `/var/log` |
| `@pkg` | `/var/cache/pacman/pkg` |
| `@development` | `/development` |
| `@snapshots` | `/.snapshots` |

All subvolumes use `compress=zstd:3` in `/etc/fstab` for transparent compression.

---

## Part 1 — Bootable Snapshots (Limine + Snapper)

The idea here is that Snapper manages snapshot creation and retention, while `limine-snapper-sync` keeps the Limine boot menu in sync with available snapshots. Booting into a snapshot mounts the filesystem read-only with an overlayfs writable layer on top — enough to assess the situation and trigger a restore.

### Dependencies

```bash
sudo pacman -S limine snapper inotify-tools
yay -S limine-mkinitcpio-hook limine-snapper-sync
```

`limine-mkinitcpio-hook` regenerates `/boot/limine.conf` automatically on every kernel update via a pacman hook. `limine-snapper-sync` watches `/.snapshots` via inotify and updates the boot menu whenever a snapshot is created or deleted — no manual intervention needed.

### Limine Configuration

Key settings in `/etc/default/limine`:

```bash
KERNEL_CMDLINE[default]+=root="LABEL=Magnolia" rootflags=subvol=@ audit=0 rw usbcore.autosuspend=-1
KERNEL_CMDLINE[default]+=initrd=/intel-ucode.img
ROOT_SUBVOLUME_PATH="/@"
ROOT_SNAPSHOTS_PATH="/@snapshots"
SNAPPER_CONFIG_NAME="root"
RESTORE_METHOD=replace
MAX_SNAPSHOT_ENTRIES=4
ENABLE_VERIFICATION=yes
BOOT_ORDER="*, *fallback, Snapshots"
FIND_BOOTLOADERS=yes
```

`RESTORE_METHOD=replace` means the restore process creates a new subvolume from the selected snapshot and replaces the current `@` — clean and reversible. After a restore, a `backup` entry is added to the boot menu so you can undo the restore if needed.

`MAX_SNAPSHOT_ENTRIES=4` keeps the boot menu uncluttered while still giving you a useful history window.

### Snapper Configuration

```bash
sudo cp /usr/share/snapper/config-templates/default /etc/snapper/configs/root
echo 'SNAPPER_CONFIGS="root"' | sudo tee /etc/conf.d/snapper
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer
sudo systemctl enable --now limine-snapper-sync.service
```

Retention policy in `/etc/snapper/configs/root` — aggressive enough to be useful, conservative enough not to fill the disk:

```
NUMBER_LIMIT="20"
NUMBER_LIMIT_IMPORTANT="10"
TIMELINE_LIMIT_HOURLY="5"
TIMELINE_LIMIT_DAILY="7"
TIMELINE_LIMIT_MONTHLY="3"
```

Always create a baseline snapshot after initial setup and mark it as important so it survives cleanup:

```bash
sudo snapper -c root create --description "stable-baseline"
sudo snapper -c root modify --description "stable-baseline" --userdata "important=yes" 1
```

### Boot Menu

```
Limine boot menu
├── Arch Linux  [+]
│   ├── linux-lts
│   ├── linux
│   └── Snapshots  [+]
│       ├── 1 │ 2026-03-05 — stable-baseline
│       └── ...  (4 entries max)
├── Systemd-boot  (fallback)
└── EFI fallback
```

`systemd-boot` is kept as a fallback entry — if Limine ever has a problem, you can still boot the system.

### Restoring a Snapshot

Boot into the target snapshot from the Limine menu, then either:

- **Desktop notification** — click **Restore now** when it appears on the desktop
- **Command line** — `sudo limine-snapper-restore` for an interactive menu

After restoration, a **"backup"** entry is added to the Limine menu pointing to the previous state, so you can undo the restore if the snapshot turns out not to be what you wanted.

### Useful Commands

| Command | Description |
|---|---|
| `limine-snapper-sync` | Manually update snapshot entries in limine.conf |
| `limine-snapper-list` | List all bootable snapshots |
| `limine-snapper-info` | Show versions and verification status |
| `limine-snapper-restore` | Restore a selected snapshot interactively |
| `limine-snapper-remove <ID1>..<ID2>` | Remove entries to free ESP space |

---

## Part 2 — Incremental Backup to External Drive

Weekly incremental backups using `btrfs send -p | btrfs receive`. After an initial full send, only the diff between the previous and current snapshot is transferred — typically a few GB per week rather than the full 70-80 GB of a home directory.

### Repository Structure

| File | Function |
|---|---|
| `btrfs-backup.sh` | Main backup script |
| `btrfs-backup.service` | Systemd service unit |
| `btrfs-backup.timer` | Runs weekly (Sunday 04:15) |

### What is Backed Up

| Source | Destination | Method |
|---|---|---|
| `/home/gabx.homedir` | `/backup/home/snaps/` | incremental via `home-parent` |
| `/development` | `/backup/development/snaps/` | incremental via `dev-parent` |
| `/.snapshots/<ID>/snapshot` | `/backup/root/snaps/` | incremental via state file |

### How Incremental Send Works

For home and development, a persistent parent snapshot is kept locally. Each run creates a new snapshot, sends only the diff relative to the parent, then promotes the new snapshot to parent for the next run:

```
/home/.local-snapshots-gabx/
├── home-parent    (last sent snapshot — used as btrfs parent)
└── home-latest    (new snapshot — temporary, becomes parent after send)

/development/.local-snapshots/
├── dev-parent
└── dev-latest
```

For root, the script uses consecutive Snapper snapshots as parent/child pairs. The last sent snapshot ID is stored in `/etc/btrfs-backup-root.state` and read at the start of each run. If the parent snapshot no longer exists locally (cleaned up by Snapper), the script falls back to a full send automatically.

### Safety Checks

Before doing anything, the script verifies:

- External disk UUID matches the expected value
- Disk is actually mounted on `/backup` (not just plugged in)
- At least 10 GB of free space available
- homectl reports gabx as active (home directory accessible)

If any check fails, the script exits cleanly without touching anything.

### Snapshot Retention

3 most recent snapshots kept on `/backup` per source. Older ones are deleted via `btrfs subvolume delete` — not just `rm -rf`, which would leave orphaned btrfs metadata.

### Email Notifications

Every run sends an email with the full log attached, regardless of outcome:

- `[OK] Backup magnolia — YYYY-MM-DD-HHMM`
- `[ECHEC] Backup magnolia — YYYY-MM-DD-HHMM`

Uses `s-nail` with a Gmail app password (standard 2FA account, dedicated sender address). Configure `~/.mailrc`:

```
set mta=smtp://smtp.gmail.com:587
set smtp-use-starttls
set smtp-auth=login
set smtp-auth-user="sender@gmail.com"
set smtp-auth-password="xxxx xxxx xxxx xxxx"
set from="sender@gmail.com"
```

### Installation

```bash
sudo cp btrfs-backup.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/btrfs-backup.sh
sudo cp btrfs-backup.service btrfs-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now btrfs-backup.timer
```

### Initial Setup (first run only)

Before incremental sends can work, a full send must establish the parent chain on the destination. This only needs to be done once:

```bash
# Create initial local parent snapshots
sudo btrfs subvolume snapshot -r /home/gabx.homedir \
    /home/.local-snapshots-gabx/home-parent
sudo btrfs subvolume snapshot -r /development \
    /development/.local-snapshots/dev-parent

# Full send to /backup (this will take a while)
sudo btrfs send /home/.local-snapshots-gabx/home-parent \
    | sudo btrfs receive /backup/home/snaps/
sudo btrfs send /development/.local-snapshots/dev-parent \
    | sudo btrfs receive /backup/development/snaps/

# Rename received snapshots with a date
sudo mv /backup/home/snaps/home-parent /backup/home/snaps/home-YYYY-MM-DD
sudo mv /backup/development/snaps/dev-parent /backup/development/snaps/dev-YYYY-MM-DD

# For root: full send of a snapper snapshot (e.g. ID=1, the stable-baseline)
sudo btrfs send /.snapshots/1/snapshot | sudo btrfs receive /backup/root/snaps/
sudo mv /backup/root/snaps/snapshot /backup/root/snaps/root-YYYY-MM-DD
echo "1" | sudo tee /etc/btrfs-backup-root.state
```

From this point on, all subsequent runs by the timer will be incremental.

---

## Active Services

| Service / Timer | Role |
|---|---|
| `limine-snapper-sync.service` | inotify watcher — updates limine.conf on snapshot changes |
| `snapper-timeline.timer` | Creates hourly snapshots |
| `snapper-cleanup.timer` | Enforces retention policy |
| `btrfs-backup.timer` | Weekly incremental backup (Sunday 04:15) |

---

## Requirements

- Arch Linux with btrfs filesystem and a clean subvolume layout
- Limine bootloader (UEFI), 1 GB ESP recommended
- External btrfs disk mounted at `/backup`
- `s-nail` configured for email notifications (`~/.mailrc`)
- `snapper`, `inotify-tools`, `limine-snapper-sync` installed
- `yay` or another AUR helper for `limine-mkinitcpio-hook` and `limine-snapper-sync`

---

## License

MIT License.
