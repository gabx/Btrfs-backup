#!/bin/bash
# ==============================================================================
# btrfs-backup.sh — Sauvegarde incrémentale btrfs (home + development + root)
# Placé dans /usr/local/bin/btrfs-backup.sh
# Exécuté en root via btrfs-backup.service / btrfs-backup.timer
#
# Principe du send incrémental pour home et development :
#   - home-parent / dev-parent : snapshot précédent, sert de parent btrfs
#   - à chaque backup : nouveau snapshot → send -p parent → parent remplacé
#
# Pour root : utilise les snapshots snapper dans /.snapshots
#   - /etc/btrfs-backup-root.state : stocke l'ID du dernier snapshot envoyé
# ==============================================================================

# ==============================================================================
# CONFIGURATION
# ==============================================================================
TARGET_UUID="dccf798a-53a3-4fe5-aa77-95dc0fd28458"
BACKUP_ROOT="/backup"
MAIL_TO="ton.adresse@gmail.com"

SRC_HOME="/home/gabx.homedir"
SRC_HOME_SNAPS_DIR="/home/.local-snapshots-gabx"
SRC_HOME_PARENT="$SRC_HOME_SNAPS_DIR/home-parent"
SRC_HOME_LATEST="$SRC_HOME_SNAPS_DIR/home-latest"

SRC_DEV="/development"
SRC_DEV_SNAPS_DIR="/development/.local-snapshots"
SRC_DEV_PARENT="$SRC_DEV_SNAPS_DIR/dev-parent"
SRC_DEV_LATEST="$SRC_DEV_SNAPS_DIR/dev-latest"

SRC_ROOT_SNAPS_DIR="/.snapshots"
ROOT_STATE_FILE="/etc/btrfs-backup-root.state"

DEST_HOME="$BACKUP_ROOT/home/snaps"
DEST_DEV="$BACKUP_ROOT/development/snaps"
DEST_ROOT="$BACKUP_ROOT/root/snaps"
ANALYSIS_DIR="$BACKUP_ROOT/analysis_daily"

MIN_SPACE=10485760 # 10 Go en Ko
RETAIN_COUNT=3

DATE="$(date +%Y-%m-%d-%H%M)"
DATE_SHORT="$(date +%Y-%m-%d)"
# ==============================================================================

# ------------------------------------------------------------------------------
# TRAP
# ------------------------------------------------------------------------------
_on_exit() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    local msg
    msg="[FATAL] Script terminated unexpectedly (exit code: $exit_code) at line ${BASH_LINENO[0]}"
    echo "$msg" >&2
    if [[ -n "${LOGFILE:-}" ]]; then
      printf "%s\n" "$msg" >>"$LOGFILE"
      # Envoi email d'échec
      {
        echo "Le backup a échoué sur magnolia."
        echo ""
        cat "$LOGFILE"
      } | mail -s "[ECHEC] Backup magnolia - $DATE" "$MAIL_TO" 2>/dev/null || true
    fi
  fi
}
trap '_on_exit' EXIT

# ------------------------------------------------------------------------------
# FONCTIONS UTILITAIRES
# ------------------------------------------------------------------------------

log_msg() {
  printf "%s\n" "$*" | tee -a "$LOGFILE"
}

log_err() {
  printf "[ERROR] %s\n" "$*" | tee -a "$LOGFILE" >&2
}

# ------------------------------------------------------------------------------
# SÉCURITÉ 1 : HOMED
# ------------------------------------------------------------------------------
if ! homectl inspect gabx 2>/dev/null | grep -q "State: active"; then
  echo "L'utilisateur gabx n'est pas actif (dossier démonté). Backup annulé."
  exit 0
fi

# ------------------------------------------------------------------------------
# SÉCURITÉ 2 : DISQUE EXTERNE
# ------------------------------------------------------------------------------
if ! lsblk -o UUID 2>/dev/null | grep -q "$TARGET_UUID"; then
  echo "⚠️  Disque externe (UUID: $TARGET_UUID) non détecté. Backup ignoré."
  exit 0
fi

if ! findmnt "$BACKUP_ROOT" >/dev/null 2>&1; then
  echo "❌ Le disque est branché mais PAS monté sur $BACKUP_ROOT."
  exit 1
fi

CURRENT_UUID=$(findmnt -no UUID "$BACKUP_ROOT")
if [[ "$CURRENT_UUID" != "$TARGET_UUID" ]]; then
  echo "❌ ALERTE SÉCURITÉ : Le disque monté sur $BACKUP_ROOT n'est pas le bon !"
  exit 1
fi

# ------------------------------------------------------------------------------
# SÉCURITÉ 3 : ESPACE DISQUE
# ------------------------------------------------------------------------------
AVAILABLE_SPACE=$(df -k --output=avail "$BACKUP_ROOT" | tail -1)
if [[ "$AVAILABLE_SPACE" -lt "$MIN_SPACE" ]]; then
  echo "[CRITICAL] Not enough space on $BACKUP_ROOT (available: ${AVAILABLE_SPACE}k, required: ${MIN_SPACE}k). Aborting."
  exit 1
fi

# ------------------------------------------------------------------------------
# INITIALISATION
# ------------------------------------------------------------------------------
mkdir -p "$ANALYSIS_DIR" "$SRC_HOME_SNAPS_DIR" "$SRC_DEV_SNAPS_DIR" "$DEST_HOME" "$DEST_DEV" "$DEST_ROOT"

LOGFILE="$ANALYSIS_DIR/${DATE_SHORT}.txt"

printf "Backup report – %s\n" "$DATE" >"$LOGFILE"
printf "Disk UUID verified: %s\n" "$TARGET_UUID" >>"$LOGFILE"
printf "%s\n" "----------------------------------------" >>"$LOGFILE"

# ------------------------------------------------------------------------------
# VÉRIFICATION SUBVOLUMES
# ------------------------------------------------------------------------------
_assert_is_subvolume() {
  local path="$1"
  if ! btrfs subvolume show "$path" >/dev/null 2>&1; then
    log_err "$path n'est pas un subvolume btrfs valide. Backup annulé."
    exit 1
  fi
}

############################################
### FUNCTION : retain_last_n
############################################
retain_last_n() {
  local DIR="$1"
  local N="${2:-$RETAIN_COUNT}"

  log_msg "[Retention] Checking $DIR"

  if [[ ! -d "$DIR" ]]; then
    log_err "[Retention] Directory $DIR does not exist."
    return 1
  fi

  mapfile -t snaps < <(find "$DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort)
  local count="${#snaps[@]}"

  if ((count <= N)); then
    log_msg "[Retention] Nothing to delete (count=$count)."
    return 0
  fi

  local to_delete=$((count - N))
  log_msg "[Retention] Deleting $to_delete old snapshot(s) (keeping $N)."

  for ((i = 0; i < to_delete; i++)); do
    local snap="$DIR/${snaps[$i]}"
    log_msg "[Retention] Removing $snap"
    if ! btrfs subvolume delete "$snap" >>"$LOGFILE" 2>&1; then
      log_err "[Retention] Failed to delete $snap"
    fi
  done
}

############################################
### FUNCTION : process_backup
### Send incrémental avec parent persistant
############################################
process_backup() {
  local SOURCE_SUBVOL="$1"
  local SNAP_DIR="$2"
  local PARENT_SNAP="$3"
  local LATEST_SNAP="$4"
  local DEST_DIR="$5"
  local NAME_PREFIX="$6"

  log_msg "=== $NAME_PREFIX BACKUP START ==="

  _assert_is_subvolume "$SOURCE_SUBVOL"

  # Supprimer un éventuel latest résiduel
  if [[ -d "$LATEST_SNAP" ]]; then
    log_msg "[$NAME_PREFIX] Removing residual latest snapshot"
    if ! btrfs subvolume delete "$LATEST_SNAP" >>"$LOGFILE" 2>&1; then
      log_err "[$NAME_PREFIX] Failed to delete residual latest"
      exit 1
    fi
  fi

  # Créer le nouveau snapshot (read-only)
  log_msg "[$NAME_PREFIX] Creating new snapshot at $LATEST_SNAP"
  if ! btrfs subvolume snapshot -r "$SOURCE_SUBVOL" "$LATEST_SNAP" >>"$LOGFILE" 2>&1; then
    log_err "[$NAME_PREFIX] Failed to create snapshot"
    exit 1
  fi

  local SNAP_NAME="${NAME_PREFIX}-${DATE}"
  local TEMP_RECV_NAME
  TEMP_RECV_NAME="$(basename "$LATEST_SNAP")"
  local TEMP_RECV_PATH="$DEST_DIR/$TEMP_RECV_NAME"

  # Nettoyage résiduel sur destination
  if [[ -e "$TEMP_RECV_PATH" ]]; then
    log_msg "[$NAME_PREFIX] Cleaning leftover on destination: $TEMP_RECV_PATH"
    btrfs subvolume delete "$TEMP_RECV_PATH" >>"$LOGFILE" 2>&1 || rm -rf "$TEMP_RECV_PATH"
  fi

  # Send incrémental si parent disponible, sinon full
  if [[ -d "$PARENT_SNAP" ]]; then
    log_msg "[$NAME_PREFIX] Sending INCREMENTAL (parent: $(basename "$PARENT_SNAP")) → $DEST_DIR/$SNAP_NAME"
    btrfs send -p "$PARENT_SNAP" "$LATEST_SNAP" 2>>"$LOGFILE" | btrfs receive "$DEST_DIR" >>"$LOGFILE" 2>&1
  else
    log_msg "[$NAME_PREFIX] No parent found, sending FULL → $DEST_DIR/$SNAP_NAME"
    btrfs send "$LATEST_SNAP" 2>>"$LOGFILE" | btrfs receive "$DEST_DIR" >>"$LOGFILE" 2>&1
  fi

  local send_rc="${PIPESTATUS[0]}" recv_rc="${PIPESTATUS[1]}"
  if [[ "$send_rc" -ne 0 || "$recv_rc" -ne 0 ]]; then
    log_err "[$NAME_PREFIX] CRITICAL: send/receive failed (send=$send_rc, receive=$recv_rc)"
    exit 1
  fi

  # Renommage du snapshot reçu
  if [[ -d "$TEMP_RECV_PATH" ]]; then
    if mv "$TEMP_RECV_PATH" "$DEST_DIR/$SNAP_NAME" 2>>"$LOGFILE"; then
      log_msg "[$NAME_PREFIX] Renamed to $SNAP_NAME"
    else
      log_err "[$NAME_PREFIX] mv failed: $TEMP_RECV_PATH → $DEST_DIR/$SNAP_NAME"
      exit 1
    fi
  else
    log_err "[$NAME_PREFIX] $TEMP_RECV_PATH not found after receive."
    exit 1
  fi

  # Rotation du parent local : latest devient le nouveau parent
  if [[ -d "$PARENT_SNAP" ]]; then
    log_msg "[$NAME_PREFIX] Deleting old parent snapshot"
    if ! btrfs subvolume delete "$PARENT_SNAP" >>"$LOGFILE" 2>&1; then
      log_err "[$NAME_PREFIX] Failed to delete old parent"
      exit 1
    fi
  fi

  log_msg "[$NAME_PREFIX] Promoting latest → parent"
  if ! mv "$LATEST_SNAP" "$PARENT_SNAP" 2>>"$LOGFILE"; then
    log_err "[$NAME_PREFIX] Failed to rename latest → parent"
    exit 1
  fi

  retain_last_n "$DEST_DIR"
  log_msg "=== $NAME_PREFIX BACKUP DONE ==="
}

############################################
### FUNCTION : process_backup_root
### Send incrémental via snapshots snapper
### Le dernier ID envoyé est stocké dans ROOT_STATE_FILE
############################################
process_backup_root() {
  log_msg "=== ROOT BACKUP START ==="

  # Lire l'ID du dernier snapshot envoyé
  local LAST_SENT_ID=""
  if [[ -f "$ROOT_STATE_FILE" ]]; then
    LAST_SENT_ID=$(cat "$ROOT_STATE_FILE")
    log_msg "[ROOT] Last sent snapshot ID: $LAST_SENT_ID"
  fi

  # Trouver le snapshot snapper le plus récent
  local LATEST_SNAP_ID
  LATEST_SNAP_ID=$(find "$SRC_ROOT_SNAPS_DIR" -maxdepth 2 -name "snapshot" -type d |
    sort -t/ -k3 -n | tail -1 | cut -d/ -f3)

  if [[ -z "$LATEST_SNAP_ID" ]]; then
    log_err "[ROOT] No snapper snapshot found. Skipping."
    return 1
  fi

  local SRC_SNAP="$SRC_ROOT_SNAPS_DIR/$LATEST_SNAP_ID/snapshot"
  log_msg "[ROOT] Latest snapper snapshot: ID=$LATEST_SNAP_ID"
  _assert_is_subvolume "$SRC_SNAP"

  # Si le dernier envoyé est le même que le plus récent, rien à faire
  if [[ "$LAST_SENT_ID" == "$LATEST_SNAP_ID" ]]; then
    log_msg "[ROOT] Snapshot ID=$LATEST_SNAP_ID already sent. Nothing to do."
    log_msg "=== ROOT BACKUP DONE ==="
    return 0
  fi

  local SNAP_NAME="root-${DATE}"
  local TEMP_RECV_PATH="$DEST_ROOT/snapshot"

  # Nettoyage résiduel
  if [[ -e "$TEMP_RECV_PATH" ]]; then
    log_msg "[ROOT] Cleaning leftover: $TEMP_RECV_PATH"
    btrfs subvolume delete "$TEMP_RECV_PATH" >>"$LOGFILE" 2>&1 || rm -rf "$TEMP_RECV_PATH"
  fi

  # Send incrémental si on a un parent valide
  local PARENT_SNAP=""
  if [[ -n "$LAST_SENT_ID" ]]; then
    PARENT_SNAP="$SRC_ROOT_SNAPS_DIR/$LAST_SENT_ID/snapshot"
    if ! btrfs subvolume show "$PARENT_SNAP" >/dev/null 2>&1; then
      log_msg "[ROOT] Parent ID=$LAST_SENT_ID no longer exists locally, falling back to FULL send"
      PARENT_SNAP=""
    fi
  fi

  if [[ -n "$PARENT_SNAP" ]]; then
    log_msg "[ROOT] Sending INCREMENTAL (parent: ID=$LAST_SENT_ID) → $DEST_ROOT/$SNAP_NAME"
    btrfs send -p "$PARENT_SNAP" "$SRC_SNAP" 2>>"$LOGFILE" | btrfs receive "$DEST_ROOT" >>"$LOGFILE" 2>&1
  else
    log_msg "[ROOT] No parent, sending FULL → $DEST_ROOT/$SNAP_NAME"
    btrfs send "$SRC_SNAP" 2>>"$LOGFILE" | btrfs receive "$DEST_ROOT" >>"$LOGFILE" 2>&1
  fi

  local send_rc="${PIPESTATUS[0]}" recv_rc="${PIPESTATUS[1]}"
  if [[ "$send_rc" -ne 0 || "$recv_rc" -ne 0 ]]; then
    log_err "[ROOT] CRITICAL: send/receive failed (send=$send_rc, receive=$recv_rc)"
    exit 1
  fi

  # Renommage
  if [[ -d "$TEMP_RECV_PATH" ]]; then
    if mv "$TEMP_RECV_PATH" "$DEST_ROOT/$SNAP_NAME" 2>>"$LOGFILE"; then
      log_msg "[ROOT] Renamed to $SNAP_NAME"
    else
      log_err "[ROOT] mv failed: $TEMP_RECV_PATH → $DEST_ROOT/$SNAP_NAME"
      exit 1
    fi
  else
    log_err "[ROOT] $TEMP_RECV_PATH not found after receive."
    exit 1
  fi

  # Sauvegarder l'ID du snapshot envoyé
  echo "$LATEST_SNAP_ID" >"$ROOT_STATE_FILE"
  log_msg "[ROOT] State updated: last sent ID=$LATEST_SNAP_ID"

  retain_last_n "$DEST_ROOT"
  log_msg "=== ROOT BACKUP DONE ==="
}

############################################
### EXÉCUTION
############################################

process_backup "$SRC_HOME" "$SRC_HOME_SNAPS_DIR" "$SRC_HOME_PARENT" "$SRC_HOME_LATEST" "$DEST_HOME" "home"
process_backup "$SRC_DEV" "$SRC_DEV_SNAPS_DIR" "$SRC_DEV_PARENT" "$SRC_DEV_LATEST" "$DEST_DEV" "dev"
process_backup_root

log_msg ""
log_msg "=== Disk usage (df -h) ==="
df -h "$BACKUP_ROOT" | tee -a "$LOGFILE"

log_msg ""
log_msg "=== Completed successfully ==="

# Envoi email de succès
{
  echo "Subject: [OK] Backup magnolia - $DATE"
  echo ""
  echo "Le backup s'est terminé avec succès sur magnolia."
  echo ""
  cat "$LOGFILE"
} | msmtp "$MAIL_TO" 2>/dev/null || true

exit 0
