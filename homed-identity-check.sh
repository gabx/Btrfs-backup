#!/bin/bash
# ==============================================================================
# homed-identity-check.sh — Vérifie et répare la cohérence des fichiers
# identity de systemd-homed pour l'utilisateur gabx.
#
# Placé dans /usr/local/bin/homed-identity-check.sh
# Exécuté en root via homed-identity-check.service / homed-identity-check.timer
#
# Vérifie que :
#   1. Le fichier host /var/lib/systemd/home/gabx.identity est valide et signé
#   2. Le fichier embarqué /home/gabx.homedir/.identity est présent et signé
#   3. Les deux fichiers ont le même lastChangeUSec (sont en sync)
#
# Si une divergence est détectée, re-signe le fichier embarqué avec la clé
# privée de homed et force un homectl update pour resynchroniser.
# ==============================================================================

set -uo pipefail

HOST_IDENTITY="/var/lib/systemd/home/gabx.identity"
EMBEDDED_IDENTITY="/home/gabx.homedir/.identity"
PRIVATE_KEY="/var/lib/systemd/home/local.private"
LOGFILE="/var/log/homed-identity-check.log"
USER="gabx"

# ==============================================================================
log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE"; }
log_err() { printf "[%s] ERROR: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOGFILE" >&2; }
# ==============================================================================

log "=== homed identity check started ==="

# --- Vérifications préalables ---
if [[ ! -f "$HOST_IDENTITY" ]]; then
    log_err "Host identity file not found: $HOST_IDENTITY"
    exit 1
fi

if [[ ! -f "$PRIVATE_KEY" ]]; then
    log_err "homed private key not found: $PRIVATE_KEY"
    exit 1
fi

if [[ ! -f "$EMBEDDED_IDENTITY" ]]; then
    log_err "Embedded identity file not found: $EMBEDDED_IDENTITY"
    log "Will attempt to re-sign and recreate embedded identity."
    NEEDS_RESIGN=true
else
    # Compare les timestamps lastChangeUSec
    HOST_TS=$(python3 -c "import json; d=json.load(open('$HOST_IDENTITY')); print(d.get('lastChangeUSec', 0))")
    EMBEDDED_TS=$(python3 -c "import json; d=json.load(open('$EMBEDDED_IDENTITY')); print(d.get('lastChangeUSec', 0))")

    log "Host lastChangeUSec:     $HOST_TS"
    log "Embedded lastChangeUSec: $EMBEDDED_TS"

    if [[ "$HOST_TS" == "$EMBEDDED_TS" ]]; then
        log "Identity files are in sync. Nothing to do."
        log "=== check completed OK ==="
        exit 0
    fi

    log "Timestamps differ — re-signing embedded identity."
    NEEDS_RESIGN=true
fi

if [[ "${NEEDS_RESIGN:-false}" == "true" ]]; then
    log "Re-signing embedded .identity..."

    python3 - << 'EOF' >> "$LOGFILE" 2>&1
import json, base64, sys
from cryptography.hazmat.primitives.serialization import (
    load_pem_private_key, Encoding, PublicFormat, load_pem_public_key
)

HOST_IDENTITY   = "/var/lib/systemd/home/gabx.identity"
EMBEDDED_IDENTITY = "/home/gabx.homedir/.identity"
PRIVATE_KEY     = "/var/lib/systemd/home/local.private"

with open(PRIVATE_KEY, "rb") as f:
    private_key = load_pem_private_key(f.read(), password=None)

with open(HOST_IDENTITY, "r") as f:
    identity = json.load(f)

# Le fichier embarqué ne doit pas contenir binding, status, signature
exclude = {"signature", "binding", "status"}
embedded = {k: v for k, v in identity.items() if k not in exclude}

# systemd signe en JSON compact trié (sd_json_variant_format flag=0)
to_sign = json.dumps(embedded, sort_keys=True, separators=(',', ':')).encode()

signature = private_key.sign(to_sign)
sig_b64 = base64.b64encode(signature).decode()
pub_pem = private_key.public_key().public_bytes(
    Encoding.PEM, PublicFormat.SubjectPublicKeyInfo
).decode()

# Vérifie la signature avant d'écrire
pub_key = load_pem_public_key(pub_pem.encode())
try:
    pub_key.verify(base64.b64decode(sig_b64), to_sign)
except Exception as e:
    print(f"FATAL: signature verification failed before write: {e}", file=sys.stderr)
    sys.exit(1)

embedded["signature"] = [{"data": sig_b64, "key": pub_pem}]

with open(EMBEDDED_IDENTITY, "w") as f:
    json.dump(embedded, f, indent="\t")
    f.write("\n")

import os, stat
os.chmod(EMBEDDED_IDENTITY, stat.S_IRUSR | stat.S_IWUSR)  # 600

print("Embedded .identity re-signed and written successfully.")
EOF

    PYTHON_EXIT=$?
    if [[ $PYTHON_EXIT -ne 0 ]]; then
        log_err "Python re-sign script failed (exit $PYTHON_EXIT)"
        exit 1
    fi

    log "Re-sign successful. Restarting systemd-homed..."
    systemctl restart systemd-homed
    sleep 2

    # Tente d'activer le home si inactif
    HOMED_STATE=$(homectl inspect "$USER" 2>/dev/null | awk '/State:/ {print $2}')
    log "Home state after restart: $HOMED_STATE"

    if [[ "$HOMED_STATE" != "active" ]]; then
        log "Home is not active — skipping homectl update (requires password interactively)."
        log "Run manually: homectl update $USER --real-name=\"$(homectl inspect $USER | awk '/Real Name:/ {print $3, $4}')\" "
    else
        log "Home is active — forcing homectl update to resync identity files..."
        # Récupère le realName depuis le host identity
        REAL_NAME=$(python3 -c "import json; d=json.load(open('$HOST_IDENTITY')); print(d.get('realName',''))")
        if homectl update "$USER" --real-name="$REAL_NAME" >> "$LOGFILE" 2>&1; then
            log "homectl update succeeded — identity files are now fully in sync."
        else
            log_err "homectl update failed — manual intervention may be required."
            exit 1
        fi
    fi
fi

log "=== check completed ==="
exit 0
