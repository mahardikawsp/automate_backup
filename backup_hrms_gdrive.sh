#!/usr/bin/env bash
# ==============================================================================
# Script Otomatisasi Backup HRMS ke Google Drive
# - Exclude private files (>600MB)
# - Langsung hapus backup lokal setelah upload sukses
# - Logging otomatis ke ~/backup_hrms/backup.log
# ==============================================================================

set -eo pipefail

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BASE_DIR="/home/ubuntu/backup_hrms"
HOST_BACKUP_DIR="${BASE_DIR}/backups/${TIMESTAMP}"
LOG_FILE="${BASE_DIR}/backup.log"
SITE_NAME="hrms.localhost"
RCLONE_REMOTE="gdrive:Backups_HRMS"
RETENTION_DAYS_GDRIVE=30

mkdir -p "$BASE_DIR"

# Redirect semua output ke terminal sekaligus ke file log
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "========================================================"
log "Memulai proses backup otomatis HRMS..."

# 1. Deteksi Container ID Dinamis
CONTAINER_ID=$(docker ps --filter "name=docker-frappe" --format "{{.ID}}" | head -n 1)
if [ -z "$CONTAINER_ID" ]; then
    CONTAINER_ID=$(docker ps --filter "name=frappe" --format "{{.ID}}" | head -n 1)
fi
if [ -z "$CONTAINER_ID" ]; then
    CONTAINER_ID="15be7bf4c4ae"
fi

log "Container ID: ${CONTAINER_ID}"

# 2. Jalankan bench backup di container
log "Menjalankan bench backup untuk site ${SITE_NAME}..."
docker exec -w /home/frappe/frappe-bench "$CONTAINER_ID" bench --site "$SITE_NAME" backup --with-files

# 3. Salin file backup dari container ke host
mkdir -p "$HOST_BACKUP_DIR"
CONTAINER_BACKUP_PATH="/home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups"
log "Menyalin file backup ke host..."
docker cp "${CONTAINER_ID}:${CONTAINER_BACKUP_PATH}/." "$HOST_BACKUP_DIR/"

# 4. Hapus file private di host agar tidak memakan ruang
rm -f "$HOST_BACKUP_DIR"/*private-files* || true

# 5. Upload ke Google Drive (Exclude private files)
log "Mengunggah file ke Google Drive (${RCLONE_REMOTE}/${TIMESTAMP})..."
rclone copy "$HOST_BACKUP_DIR" "${RCLONE_REMOTE}/${TIMESTAMP}" \
    --exclude "*private-files*" \
    --transfers 4 \
    --checkers 8

log "Upload ke Google Drive BERHASIL!"

# 6. HAPUS FOLDER BACKUP DI HOST (Agar disk server tetap bersih 0 MB)
log "Menghapus folder backup lokal di host (${HOST_BACKUP_DIR})..."
rm -rf "$HOST_BACKUP_DIR"
# Hapus juga folder-folder backup lama yang mungkin masih tertinggal
rm -rf "${BASE_DIR}/backups"/* || true
log "Pembersihan disk host server selesai."

# 7. Bersihkan arsip lama di dalam Docker container (> 2 hari)
docker exec "$CONTAINER_ID" find "$CONTAINER_BACKUP_PATH" -type f -mtime +2 -delete || true

# 8. Bersihkan arsip lama di Google Drive (> 30 hari)
rclone delete --min-age "${RETENTION_DAYS_GDRIVE}d" "${RCLONE_REMOTE}" || true

log "Seluruh alur backup HRMS selesai dengan sempurna!"
log "========================================================"