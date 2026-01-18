#!/bin/bash
set -euo pipefail

# --- SECURITE HOMED ---
# vérifier si l'utilisateur gabx est actif et le dossier monté
# si homectl ne dit pas "active", on arrete
if ! homectl list | grep -q "gabx.*active"; then
	echo "L'utilisateur gabx n'est pas connecté. Backup annulé pour éviter le verouillage"
	exit 0
fi


# --- SÉCURITÉ ESPACE DISQUE ---
# On vérifie l'espace disponible sur /backup (en Ko)
AVAILABLE_SPACE=$(df -k --output=avail /backup | tail -1)
# Seuil de sécurité : 10 Go (10 * 1024 * 1024 = 10485760 Ko)
MIN_SPACE=10485760

if [ "$AVAILABLE_SPACE" -lt "$MIN_SPACE" ]; then
    printf "[CRITICAL] Not enough space on /backup. Aborting.\n" >> "$LOGFILE"
    printf "Available: %s KB, Required: %s KB\n" "$AVAILABLE_SPACE" "$MIN_SPACE" >> "$LOGFILE"
    # On pourrait ajouter ici une commande pour vous envoyer un mail/notification
    exit 1
fi
# ------------------------------

DATE="$(date +%Y-%m-%d-%H%M)"
DATE_SHORT="$(date +%Y-%m-%d)"

# Configuration des sources
SRC_HOME="/home/gabx.homedir"
SRC_HOME_SNAPS_DIR="/home/gabx/.local-snapshots"
SRC_HOME_LATEST="$SRC_HOME_SNAPS_DIR/home-latest"

SRC_DEV="/development"
SRC_DEV_SNAPS_DIR="/development/.local-snapshots"
SRC_DEV_LATEST="$SRC_DEV_SNAPS_DIR/dev-latest"

# Configuration des destinations
DEST_HOME="/backup/home/snaps"
DEST_DEV="/backup/development/snaps"
ANALYSIS_DIR="/backup/analysis_daily"

# Création des dossiers si inexistants
mkdir -p "$DEST_HOME" "$DEST_DEV" "$ANALYSIS_DIR" "$SRC_HOME_SNAPS_DIR" "$SRC_DEV_SNAPS_DIR"

LOGFILE="$ANALYSIS_DIR/${DATE_SHORT}.txt"

# Initialisation du log
printf "Backup report – %s\n" "$DATE" > "$LOGFILE"
printf "%s\n" "----------------------------------------" >> "$LOGFILE"

############################################
### FUNCTION: retain last 7 snapshots
############################################
retain_last_7() {
    local DIR="$1"
    printf "[Retention] Checking %s\n" "$DIR" >> "$LOGFILE"

    if [ -d "$DIR" ]; then
        mapfile -t snaps < <(ls -1 "$DIR" | sort)
        local count="${#snaps[@]}"
        
        if (( count <= 7 )); then
            printf "[Retention] Nothing to delete (count=%s).\n" "$count" >> "$LOGFILE"
            return
        fi

        local to_delete=$((count - 7))
        printf "[Retention] Deleting %s old snapshots\n" "$to_delete" >> "$LOGFILE"

        for ((i=0; i<to_delete; i++)); do
            snap="${DIR}/${snaps[$i]}"
            printf "[Retention] Removing %s\n" "$snap" >> "$LOGFILE"
            sudo btrfs subvolume delete "$snap" >> "$LOGFILE" 2>&1
        done
    else
        printf "[Retention] Error: Directory %s does not exist.\n" "$DIR" >> "$LOGFILE"
    fi
}

############################################
### FUNCTION: Create & Send Snapshot
############################################
process_backup() {
    local SOURCE_SUBVOL="$1"
    local SNAP_DIR="$2"
    local LATEST_LINK="$3"
    local DEST_DIR="$4"
    local NAME_PREFIX="$5"

    printf "=== %s BACKUP START ===\n" "$NAME_PREFIX" >> "$LOGFILE"

    # 1. Nettoyage SOURCE : suppression de l'ancien snapshot local s'il existe
    if [ -d "$LATEST_LINK" ]; then
        printf "[%s] Deleting old local source snapshot %s\n" "$NAME_PREFIX" "$LATEST_LINK" >> "$LOGFILE"
        sudo btrfs subvolume delete "$LATEST_LINK" >> "$LOGFILE" 2>&1
    fi

    # 2. Création SOURCE : nouveau snapshot en lecture seule (ro)
    printf "[%s] Creating new snapshot at %s\n" "$NAME_PREFIX" "$LATEST_LINK" >> "$LOGFILE"
    sudo btrfs subvolume snapshot -r "$SOURCE_SUBVOL" "$LATEST_LINK"

    # --- AJOUT CORRECTION ICI ---
    # 3. Nettoyage DESTINATION : Vérifier s'il reste un résidu 'latest' sur la destination
    # btrfs receive va vouloir créer un dossier du même nom que la source (ex: home-latest).
    # Si ce dossier existe déjà sur la destination (crash précédent), receive échoue.
    local TEMP_RECV_NAME
    TEMP_RECV_NAME=$(basename "$LATEST_LINK")
    local TEMP_RECV_PATH="$DEST_DIR/$TEMP_RECV_NAME"

    if [ -e "$TEMP_RECV_PATH" ]; then
        printf "[%s] Cleaning up leftover temp snapshot on destination: %s\n" "$NAME_PREFIX" "$TEMP_RECV_PATH" >> "$LOGFILE"
        # On essaie de le supprimer proprement comme un subvolume
        sudo btrfs subvolume delete "$TEMP_RECV_PATH" >> "$LOGFILE" 2>&1 || \
        # Si ce n'est pas un subvolume (juste un dossier vide ou corrompu), on force rm
        sudo rm -rf "$TEMP_RECV_PATH"
    fi
    # ----------------------------

    # 4. Envoi du snapshot
    local SNAP_NAME="${NAME_PREFIX}-${DATE}"
    local DEST_SNAP="$DEST_DIR/$SNAP_NAME"

    printf "[%s] Sending FULL snapshot → %s\n" "$NAME_PREFIX" "$DEST_SNAP" >> "$LOGFILE"
    
    # On utilise un pipe et on vérifie les erreurs du pipe
    if sudo btrfs send "$LATEST_LINK" | sudo btrfs receive "$DEST_DIR"; then
        # Renommer le snapshot reçu sur la destination
        # btrfs receive a créé "$DEST_DIR/home-latest", on le renomme en "$DEST_DIR/home-2023..."
        if [ -d "$TEMP_RECV_PATH" ]; then
             sudo mv "$TEMP_RECV_PATH" "$DEST_SNAP"
             printf "[%s] Renamed received snapshot to %s\n" "$NAME_PREFIX" "$SNAP_NAME" >> "$LOGFILE"
        else
             printf "[%s] Warning: Receive succeeded but %s not found for renaming\n" "$NAME_PREFIX" "$TEMP_RECV_PATH" >> "$LOGFILE"
        fi
    else
        printf "[%s] CRITICAL ERROR: Send/Receive failed\n" "$NAME_PREFIX" >> "$LOGFILE"
        exit 1
    fi

    # 5. Rotation sur la destination
    retain_last_7 "$DEST_DIR"
}

############################################
### EXECUTION
############################################

# HOME
process_backup "$SRC_HOME" "$SRC_HOME_SNAPS_DIR" "$SRC_HOME_LATEST" "$DEST_HOME" "home"

# DEVELOPMENT
process_backup "$SRC_DEV" "$SRC_DEV_SNAPS_DIR" "$SRC_DEV_LATEST" "$DEST_DEV" "dev"

############################################
### ANALYSIS SECTION
############################################
printf "\n=== Disk usage (df -h) ===\n" >> "$LOGFILE"
df -h /backup >> "$LOGFILE"

printf "\n=== Completed successfully ===\n" >> "$LOGFILE"

exit 0
