# Btrfs Automated Backup & Maintenance Suite

This repository contains a complete, production-grade automation suite for Btrfs backups on Linux.  
It includes:

- **Full + Incremental Home and Development snapshots**
- **Automatic snapshot rotation**
- **Backup integrity checks**
- **Daily analysis logs**
- **Failure notifications via email**
- **Monthly Btrfs scrub & reporting**

The system is designed to be **simple, reliable, and crash-resistant**, with minimal assumptions about the host environment.

---

## Repository Structure


| SCRIPTS | FUNCTION |
|-----------------|---------------------------------|
| btrfs-backup.sh  |   main backup script           |
| btrfs-backup.service | Systemd service unit |
| btrfs-backup.timer | Runs nightly (03:15 AM) |
| btrfs-backup-notify.sh | Email alert for failures  |
| btrfs-backup-verify.sh | Verifies backup directory after completion |
| btrfs-backup-status.sh | Prints last run statuses |
| btrfs-scrub-backup.sh | Monthly scrub of the /backup filesystem |
| btrfs-scrub-backup.service | Systemd scrub service |
| btrfs-scrub-backup.timer | Runs monthly on the 5th at 01:00 |
| btrfs-scrub-notify.sh | Email notifications for scrub results |


## Features

### 1. Automated Backups

The system creates read-only snapshots from the live filesystem, then sends them to a dedicated `/backup` Btrfs volume.

- Full or incremental transfer (depending on availability of parent snapshot)
- Each snapshot is uniquely timestamped
- Snapshots are stored under:

**/backup/home/snaps/**

**/backup/development/snaps/**


### 2. Snapshot Rotation

To prevent the backup filesystem from filling up:

- Keeps only the **7 most recent snapshots** per source  
- Automatically deletes older ones  
- Guarantees at least one valid snapshot remains at all times  

---

### 3. Daily Analysis Logs

Each backup run generates a simple human-readable overview:

**analysis_daily/YYYY-MM-DD.txt**


This includes:

- Backup start/end times  
- Snapshot name created  
- Space usage summary  
- Rotation summary  
- Errors (if any)

This helps verify trends in disk usage and detect anomalies early.

---

### 4. Email Notifications

Backup and scrub processes can send email alerts on failure.

The system uses `mail` (s-nail) configured with a per-user `~/.mailrc`.

You will receive emails such as:

- ❌ Backup FAILED  
- ❌ Scrub FAILED  
- ✅ Scrub completed with no errors  

---

### 5. Monthly Btrfs Scrub

A scrub operation checks the entire `/backup` filesystem for errors.

- Runs monthly  
- Generates a detailed report  
- Sends an email notification if something goes wrong  


##  Installation

### 1. Copy all scripts

```
sudo cp btrfs-*.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/btrfs-*.sh
```

2. Install systemd services & timers
```
sudo cp *.service *.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now btrfs-backup.timer
sudo systemctl enable --now btrfs-scrub-backup.timer
```

3. Configure email notifications

Create a user-level config:

**~/.mailrc**

Example:
```
set mta=smtp://smtp.gmail.com:587
set smtp-use-starttls
set smtp-auth=login
set smtp-auth-user="your_email@gmail.com"
set smtp-auth-password="your_app_password"
set from="your_email@mail.com"
```
Manual Runs

```
sudo /usr/local/bin/btrfs-backup.sh home
sudo /usr/local/bin/btrfs-backup.sh dev
sudo systemctl start btrfs-scrub-backup.service
```

To check status:
```
/usr/local/bin/btrfs-backup-status.sh
```

Requirements

- Linux with Btrfs installed

- Backup filesystem mounted at /backup

- s-nail or mailx installed (for notifications)

- systemd timers active

License

MIT License.