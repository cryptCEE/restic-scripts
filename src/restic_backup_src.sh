#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Editable master: Restic backup
# -----------------------------------------------------------------------------

# -----------------------------
# Paths (portable)
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "$SCRIPT_DIR")"     # Parent folder
SRC_DIR="$SCRIPT_DIR"

RESTIC_REPOSITORY="$HOME/restic-repo"   # Optional: user home
RESTIC_PASS_FILE="$RESTIC_REPOSITORY/restic_pass"

# -----------------------------
# Argon2 password settings
# -----------------------------
PLAIN_PASSWORD="my_restic_super_secret"
SALT="backup-salt"
ARGON2_TIME=3
ARGON2_MEM=16
ARGON2_PARALLEL=4

# -----------------------------
# Backup sources
# -----------------------------
BACKUP_PATHS=(
    "$HOME/restic-scripts/src/restic_backup_src.sh"
    "$HOME/.bash_history"
    "$HOME/.screenrc"
    "$HOME/.profile"
    "$HOME/.zprofile"
    "$HOME/.bashrc"
    "$HOME/setup-tmux.sh"
    "$HOME/.tmux.conf"
    "$HOME/.zshrc"
    "$HOME/.zsh_history"
    "$HOME/.ssh"
    "$HOME/tmux-bootstrap-backup*"
)

EXCLUDES=(
    "*.sqlite3*"
    "*.log"
    "**/cache/*"
    "**/tmp/*"
)

# -----------------------------
# Logs
# -----------------------------
LOG_DIR="$RESTIC_REPOSITORY/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup_$(date '+%F').log"

# -----------------------------
# PATH
# -----------------------------
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# -----------------------------
# Create Restic repository & password
# -----------------------------
mkdir -p "$RESTIC_REPOSITORY"

if [ ! -f "$RESTIC_PASS_FILE" ]; then
    echo "$(date '+%F %T') - Creating Restic password file..." | tee -a "$LOG_FILE"
    echo -n "$PLAIN_PASSWORD" | \
      argon2 "$SALT" -id -t $ARGON2_TIME -m $ARGON2_MEM -p $ARGON2_PARALLEL -r \
      | tr -d '\n' > "$RESTIC_PASS_FILE"
    chmod 600 "$RESTIC_PASS_FILE"
else
    echo "$(date '+%F %T') - Using existing Restic password file." | tee -a "$LOG_FILE"
fi

export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"

# -----------------------------
# Helper functions
# -----------------------------
paths_to_flags() { for path in "${BACKUP_PATHS[@]}"; do echo -n "$path "; done; }
excludes_to_flags() { for pattern in "${EXCLUDES[@]}"; do echo -n "--exclude $pattern "; done; }

# -----------------------------
# Initialize repo if needed
# -----------------------------
if [ ! -d "$RESTIC_REPOSITORY/data" ]; then
    echo "$(date '+%F %T') - Initializing Restic repository..." | tee -a "$LOG_FILE"
    restic init --repo "$RESTIC_REPOSITORY" >> "$LOG_FILE" 2>&1
fi

# -----------------------------
# Run backup
# -----------------------------
echo "$(date '+%F %T') - Starting backup..." | tee -a "$LOG_FILE"
restic backup $(paths_to_flags) $(excludes_to_flags) --repo "$RESTIC_REPOSITORY" >> "$LOG_FILE" 2>&1

# -----------------------------
# Prune old snapshots
# -----------------------------
echo "$(date '+%F %T') - Pruning old snapshots..." | tee -a "$LOG_FILE"
restic forget --prune --keep-daily 30 --keep-weekly 12 --keep-monthly 6 --repo "$RESTIC_REPOSITORY" >> "$LOG_FILE" 2>&1

echo "$(date '+%F %T') - Backup completed." | tee -a "$LOG_FILE"

# -----------------------------
# Auto-setup cron
# -----------------------------
CRON_CMD="0 2 * * * $PROD_DIR/restic_backup.sh"
CRON_TMP=$(mktemp)
crontab -l 2>/dev/null | grep -F "$PROD_DIR/restic_backup.sh" >/dev/null || {
    echo "Setting up cron job for daily backup at 2 AM..."
    crontab -l 2>/dev/null > "$CRON_TMP" || true
    echo "$CRON_CMD" >> "$CRON_TMP"
    crontab "$CRON_TMP"
    rm "$CRON_TMP"
    echo "Cron job installed."
}

# -----------------------------
# Generate Restore Source
# -----------------------------
RESTORE_SRC="$SRC_DIR/restore_src.sh"

cat > "$RESTORE_SRC" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROD_DIR="$(dirname "$SCRIPT_DIR")"

RESTIC_REPOSITORY="$HOME/restic-repo"
RESTIC_PASS_FILE="$RESTIC_REPOSITORY/restic_pass"
RESTORE_DIR="$HOME/restic_restore"

export RESTIC_PASSWORD_FILE="$RESTIC_PASS_FILE"

mkdir -p "$RESTORE_DIR"

SNAPSHOTS_JSON=$(restic snapshots --json --repo "$RESTIC_REPOSITORY")
SNAP_COUNT=$(echo "$SNAPSHOTS_JSON" | jq '. | length')

if [ "$SNAP_COUNT" -eq 0 ]; then
    echo "No snapshots found."
    exit 1
fi

echo "Available snapshots (latest first):"
for i in $(seq 0 $((SNAP_COUNT-1))); do
    ID=$(echo "$SNAPSHOTS_JSON" | jq -r ".[$i].short_id")
    TIME=$(echo "$SNAPSHOTS_JSON" | jq -r ".[$i].time" | sed 's/T/ /;s/Z//')
    DATEFMT=$(date -d "$TIME" '+%d-%b-%Y %H:%M:%S')
    echo "[$i] $DATEFMT  (ID: $ID)"
done

read -rp "Enter snapshot number (or 'latest'): " SNAPSEL
SNAPSEL=${SNAPSEL:-latest}

if [ "$SNAPSEL" = "latest" ]; then
    SNAP_INDEX=$((SNAP_COUNT-1))
else
    if ! [[ "$SNAPSEL" =~ ^[0-9]+$ ]] || [ "$SNAPSEL" -lt 0 ] || [ "$SNAPSEL" -ge "$SNAP_COUNT" ]; then
        echo "Invalid selection."
        exit 1
    fi
    SNAP_INDEX=$SNAPSEL
fi

SNAPSHOT_ID=$(echo "$SNAPSHOTS_JSON" | jq -r ".[$SNAP_INDEX].short_id")
SNAP_TIME=$(echo "$SNAPSHOTS_JSON" | jq -r ".[$SNAP_INDEX].time" | sed 's/T/ /;s/Z//')
SNAP_DATEFMT=$(date -d "$SNAP_TIME" '+%d-%b-%Y %H:%M:%S')

read -rp "Restore snapshot $SNAPSHOT_ID from $SNAP_DATEFMT to $RESTORE_DIR? [Y/n]: " CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

rm -rf "$RESTORE_DIR"/*
restic restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --repo "$RESTIC_REPOSITORY"
echo "Restore complete to $RESTORE_DIR."
EOF
chmod +x "$RESTORE_SRC"

# -----------------------------
# Encrypt production scripts
# -----------------------------
mkdir -p "$PROD_DIR"

# Backup
openssl rsautl -encrypt -pubin -inkey "$HOME/.ssh/id_rsa.pub" -in "$SRC_DIR/restic_backup_src.sh" -out "$PROD_DIR/restic_backup.sh.enc"
cat > "$PROD_DIR/restic_backup.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
openssl rsautl -decrypt -inkey ~/.ssh/id_rsa -in "$SCRIPT_DIR/restic_backup.sh.enc" | bash
EOF

# Restore
openssl rsautl -encrypt -pubin -inkey "$HOME/.ssh/id_rsa.pub" -in "$RESTORE_SRC" -out "$PROD_DIR/restore.sh.enc"
cat > "$PROD_DIR/restore.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
openssl rsautl -decrypt -inkey ~/.ssh/id_rsa -in "$SCRIPT_DIR/restore.sh.enc" | bash
EOF

chmod +x "$PROD_DIR/restic_backup.sh" "$PROD_DIR/restore.sh"

echo "Encrypted production scripts generated in $PROD_DIR."
echo "Run them directly: $PROD_DIR/restic_backup.sh  and  $PROD_DIR/restore.sh"
