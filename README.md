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

## Part 1b — Restoring `/home` from Backup Snapshot

When `gabx.homedir` is inaccessible or corrupt (e.g. homectl fails with `Value too large for defined data type` or similar), restore it directly from a btrfs snapshot on `/backup`. This is near-instantaneous thanks to btrfs COW — no file-by-file copy needed.

### Available Snapshots

```bash
btrfs subvolume list /backup | grep home
# e.g.
# home/snaps/home-2026-03-05-0543
# home/snaps/home-2026-03-08-1313
```

### Restore Procedure

```bash
# 1. Stop homed
systemctl stop systemd-homed

# 2. Move aside the broken home (keep it until restore is confirmed working)
mv /home/gabx.homedir /home/gabx.homedir.broken

# 3. Instant restore via btrfs snapshot (no copy — shares blocks via COW)
btrfs subvolume snapshot \
    /backup/home/snaps/<snapshot-to-restore> \
    /home/gabx.homedir

# 4. Make the restored subvolume writable
btrfs property set /home/gabx.homedir ro false

# 5. Restart homed and activate
systemctl start systemd-homed
homectl activate gabx
```

Once the restore is confirmed working:

```bash
# Clean up the broken copy
btrfs subvolume delete /home/gabx.homedir.broken
```

### Why Not cp or rsync?

`btrfs subvolume snapshot` is the correct tool here — it is instantaneous regardless of home directory size, and uses no additional disk space until files diverge (COW). `cp -a` or `rsync` copy every byte and can take hours for a large home directory.

Use `rsync` only if you need to **exclude** specific directories (e.g. `.cache`) or merge selectively:

```bash
rsync -aHAX --progress \
    --exclude='.cache/' \
    --exclude='Downloads/' \
    /backup/home/snaps/<snapshot>/. \
    /home/gabx.homedir/
```

### Known Issue — homectl `Value too large for defined data type` (EOVERFLOW)

**Symptom:** `homectl activate gabx` fails with `Failed to move identity file into place: Value too large for defined data type`, even though the password is correct (confirmed by `journalctl -u systemd-homed`).

**Root cause:** A systemd update changed the structure of `/var/lib/systemd/home/gabx.identity` (adding fields such as `blobDirectory`, `status`, etc.), making it newer than the `.identity` file embedded inside `gabx.homedir`. During activation, `systemd-homework` attempts to reconcile the two files and write the result back into `gabx.homedir/.identity` via `renameat()`. This call fails with EOVERFLOW — a misleading error that actually indicates a signature mismatch or incoherent state between the two identity files, not a filesystem limit.

The EOVERFLOW on `renameat` is a secondary symptom. The real problem is that the embedded `.identity` is out of sync with the host identity and cannot be reconciled cleanly.

**Resolution — try this first (simple fix):**

The root cause is incorrect ownership on `.identity` or `gabx.homedir` itself, which prevents `systemd-homework` from performing the `renameat()`. See upstream bug report [systemd#38941](https://github.com/systemd/systemd/issues/38941).

First, check the current ownership:

```bash
stat /home/gabx.homedir
ls -la /home/gabx.homedir/.identity
```

When the home is **inactive**, the expected ownership is:

| Path | Expected owner |
|---|---|
| `/home/gabx.homedir/` | `nobody:nobody` |
| `/home/gabx.homedir/.identity` | `nobody:nobody` |

Two variants have been reported depending on what went wrong:

**Variant A** — `.identity` has wrong owner (`gabx:gabx` instead of `nobody:nobody`):
```bash
systemctl stop systemd-homed
chown nobody:nogroup /home/gabx.homedir/.identity
chown nobody:nogroup /home/gabx.homedir/.identity-blob/ 2>/dev/null || true
systemctl start systemd-homed
homectl activate gabx
```

**Variant B** — `gabx.homedir` itself has wrong owner (not `nobody:nobody`):
```bash
systemctl stop systemd-homed
chown nobody:nobody /home/gabx.homedir
systemctl start systemd-homed
homectl activate gabx
```

**Resolution — fallback if the above does not work (re-sign):**

If the ownership fix is not sufficient, the embedded `.identity` may also be out of sync with the host identity. Re-sign it using homed's own private key, then force a `homectl update` to let homed rewrite both files cleanly.

```bash
# Step 1 — re-sign the embedded .identity with the correct format
python3 - << 'EOF'
import json, base64
from cryptography.hazmat.primitives.serialization import load_pem_private_key, Encoding, PublicFormat

with open("/var/lib/systemd/home/local.private", "rb") as f:
    private_key = load_pem_private_key(f.read(), password=None)

with open("/var/lib/systemd/home/gabx.identity", "r") as f:
    identity = json.load(f)

# The embedded .identity must NOT contain binding, status, or signature
exclude = {"signature", "binding", "status"}
embedded = {k: v for k, v in identity.items() if k not in exclude}

# systemd signs compact JSON with sorted keys (sd_json_variant_format flag=0)
to_sign = json.dumps(embedded, sort_keys=True, separators=(',', ':')).encode()

signature = private_key.sign(to_sign)
sig_b64 = base64.b64encode(signature).decode()
pub_pem = private_key.public_key().public_bytes(Encoding.PEM, PublicFormat.SubjectPublicKeyInfo).decode()

embedded["signature"] = [{"data": sig_b64, "key": pub_pem}]

with open("/home/gabx.homedir/.identity", "w") as f:
    json.dump(embedded, f, indent="\t")
    f.write("\n")

print("Done — embedded .identity re-signed")
EOF

# Step 2 — restart homed and activate
systemctl restart systemd-homed
homectl activate gabx   # should succeed or report "already active"

# Step 3 — force homed to rewrite both identity files cleanly
homectl update gabx --real-name="Arno Gaboury"

# Step 4 — verify both files are now in sync
cat /home/gabx.homedir/.identity | grep lastChangeUSec
cat /var/lib/systemd/home/gabx.identity | grep lastChangeUSec
# Both timestamps must be identical
```

After a successful `homectl update`, both identity files are rewritten and signed by homed itself — the issue will not recur unless another systemd update causes a new divergence.

**Note on rate limiting:** A high `badAuthenticationCounter` (visible in `/var/lib/systemd/home/gabx.identity`) can trigger rate limiting and block activation independently of the above. Reset it manually if needed:

```bash
# Edit /var/lib/systemd/home/gabx.identity and set:
"badAuthenticationCounter" : 0,
"rateLimitBeginUSec" : 0,
"rateLimitCount" : 0

systemctl restart systemd-homed
```

**Note on the Python signing format:** systemd's JSON signing implementation (`sd_json_variant_format` with flag `0`) produces compact JSON with sorted keys — equivalent to Python's `json.dumps(obj, sort_keys=True, separators=(',', ':'))`. The fields excluded from signing are `signature`, `binding`, and `status` (see `user-record-sign.c`, `USER_RECORD_STRIP_BINDING | USER_RECORD_STRIP_STATUS | USER_RECORD_STRIP_SIGNATURE`).

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
sudo chmod 750 /usr/local/bin/btrfs-backup.sh
sudo chown root:root /usr/local/bin/btrfs-backup.sh
sudo cp btrfs-backup.service btrfs-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now btrfs-backup.timer
```

> **Note:** `chmod 750` is required — systemd refuses to execute the script with `Permission denied` (status 203/EXEC) if the executable bit is missing.

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
| `homed-identity-check.timer` | Weekly + on-boot check of homed identity coherence (Monday 05:00) |

---

## Part 3 — homed Identity Coherence Check

A systemd update can silently diverge the host identity file (`/var/lib/systemd/home/gabx.identity`) from the embedded identity inside `gabx.homedir/.identity`. When this happens, `homectl activate` fails with a misleading EOVERFLOW error at next login. This service detects and repairs the divergence automatically.

### How It Works

On every run, the script compares `lastChangeUSec` between the two identity files. If they differ, it:

1. Re-signs the embedded `.identity` using homed's own private key and the exact JSON format systemd expects
2. Restarts `systemd-homed`
3. Runs `homectl update` to let homed rewrite both files cleanly with its own signature

The check runs at boot (after a 30s delay to let homed start) and weekly on Monday at 05:00 — the day after the btrfs backup runs.

### Installation

```bash
sudo cp homed-identity-check.sh /usr/local/bin/
sudo chmod 750 /usr/local/bin/homed-identity-check.sh
sudo chown root:root /usr/local/bin/homed-identity-check.sh
sudo cp homed-identity-check.service homed-identity-check.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homed-identity-check.timer
```

### Manual Run

```bash
sudo systemctl start homed-identity-check.service
journalctl -u homed-identity-check.service -n 30
cat /var/log/homed-identity-check.log
```

### Limitation

If the home is inactive at check time (user not logged in, home not mounted), the script re-signs the embedded `.identity` but cannot run `homectl update` — that requires an interactive password. In this case the re-signed embedded file is enough to allow the next `homectl activate` to succeed, and homed will complete the sync on its own during activation.

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
