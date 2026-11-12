# Panduan Otomatisasi Backup HRMS (Frappe) ke Google Drive

Panduan ini berisi alur lengkap otomatisasi backup HRMS dari container Docker di server Ubuntu (`VM-6-156-ubuntu`) ke Google Drive menggunakan **Rclone OAuth Authorize**.

Fitur utama script:
- Otomatis backup Database (`.sql.gz`) & File Publik (`.tar`).
- **Exclude file private** (>600MB) agar tidak memboroskan kuota dan bandwidth.
- **Auto Clean Storage**: Menghapus sisa backup di dalam container dan host setelah upload sukses (disk tetap 0 MB).
- **Auto Detect Container**: Menyesuaikan ID container Frappe secara dinamis jika container restart.
- **Jadwal Otomatis**: Berjalan setiap jam 12:00 siang WIB dan 00:00 malam WIB.

---

## 1. Hubungkan Server Ubuntu ke Google Drive (OAuth Authorize)

Metode ini menggunakan akun Google Drive pribadi Anda secara resmi tanpa batas storage quota Service Account.

### Langkah A: Di Laptop Anda (Mac/PC yang Memiliki Browser)
1. Buka terminal di laptop Anda, jalankan:
   ```bash
   rclone authorize "drive"
   ```
   *(Jika di laptop Mac belum ada rclone: `brew install rclone`)*.
2. Browser akan terbuka otomatis. Login ke akun Google Anda dan pilih **Allow / Izinkan**.
3. Di terminal laptop akan muncul teks token JSON panjang:
   ```json
   {"access_token":"ya29...","token_type":"Bearer","refresh_token":"1//...","expiry":"..."}
   ```
4. **Copy seluruh teks token JSON tersebut** (mulai dari `{` sampai `}`).

---

### Langkah B: Di Server Ubuntu (`VM-6-156-ubuntu`)
1. Install Rclone di server (jika belum):
   ```bash
   sudo apt update && sudo apt install -y rclone
   ```
2. Jalankan konfigurasi:
   ```bash
   rclone config
   ```
3. Ikuti wizard konfigurasi:
   * Ketik `n` (New remote)
   * Name: `gdrive`
   * Storage: ketik `drive`
   * `client_id`: tekan **Enter** (kosongkan)
   * `client_secret`: tekan **Enter** (kosongkan)
   * `scope`: ketik `1` (Full access)
   * `service_account_file`: tekan **Enter** (kosongkan)
   * `edit advanced config`: ketik `n`
   * `Use auto config`: ketik **`n`** *(karena server remote tanpa GUI)*
   * Muncul prompt `result>`: **Paste kode token JSON dari laptop tadi**, lalu tekan **Enter**.
   * `Configure as Team Drive`: ketik `n`
   * `Keep this "gdrive" remote`: ketik `y`
   * Ketik `q` (quit).

---

### Langkah C: Optimasi Startup Rclone (Mempercepat Upload)
Tambahkan `root_folder_id` langsung ke konfigurasi agar rclone tidak memakan waktu lama saat startup:
```bash
nano ~/.config/rclone/rclone.conf
```
Di bawah blok `[gdrive]`, tambahkan baris berikut:
```ini
root_folder_id = 0AIU3D3_Ep5ZiUk9PVA
```
Simpan file (`Ctrl + O`, `Enter`, `Ctrl + X`).

Tes upload kilat:
```bash
echo "Tes Rclone" > test.txt
rclone copy test.txt gdrive:Backups_HRMS
rclone ls gdrive:Backups_HRMS
```

---

## 2. Pasang Script Otomatisasi di Server

1. Buat folder dan file script:
   ```bash
   mkdir -p ~/backup_hrms
   nano ~/backup_hrms/backup_hrms_gdrive.sh
   ```

2. Paste kode berikut ke dalam nano:
   ```bash
   #!/usr/bin/env bash
   # ==============================================================================
   # Script Otomatisasi Backup HRMS ke Google Drive
   # - Bersihkan backup lama di container sebelum & sesudah backup
   # - Hanya upload 1 set backup terbaru hari ini (exclude private files)
   # - Hapus total backup lokal di host & container (disk 0 MB)
   # - Logging otomatis ke ~/backup_hrms/backup.log
   # ==============================================================================

   set -eo pipefail

   TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
   BASE_DIR="/home/ubuntu/backup_hrms"
   HOST_BACKUP_DIR="${BASE_DIR}/backups/${TIMESTAMP}"
   LOG_FILE="${BASE_DIR}/backup.log"
   SITE_NAME="hrms.localhost"
   CONTAINER_BACKUP_PATH="/home/frappe/frappe-bench/sites/${SITE_NAME}/private/backups"
   RCLONE_REMOTE="gdrive:Backups_HRMS"
   RETENTION_DAYS_GDRIVE=30

   mkdir -p "$BASE_DIR"

   # Redirect output ke terminal dan file log
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

   # 2. Bersihkan arsip lama di container sebelum backup
   log "Membersihkan sisa backup lama di dalam container..."
   docker exec "$CONTAINER_ID" bash -c "rm -rf ${CONTAINER_BACKUP_PATH}/*" || true

   # 3. Jalankan bench backup di container
   log "Menjalankan bench backup untuk site ${SITE_NAME}..."
   docker exec -w /home/frappe/frappe-bench "$CONTAINER_ID" bench --site "$SITE_NAME" backup --with-files

   # 4. Hapus file private di container sebelum dicopy (Hemat I/O dan storage)
   docker exec "$CONTAINER_ID" bash -c "rm -f ${CONTAINER_BACKUP_PATH}/*private-files*" || true

   # 5. Salin HANYA file backup terbaru dari container ke host
   mkdir -p "$HOST_BACKUP_DIR"
   log "Menyalin file backup terbaru ke host..."
   docker cp "${CONTAINER_ID}:${CONTAINER_BACKUP_PATH}/." "$HOST_BACKUP_DIR/"

   # 6. Upload ke Google Drive
   log "Mengunggah file ke Google Drive (${RCLONE_REMOTE}/${TIMESTAMP})..."
   rclone copy "$HOST_BACKUP_DIR" "${RCLONE_REMOTE}/${TIMESTAMP}" \
       --transfers 4 \
       --checkers 8

   log "Upload ke Google Drive BERHASIL!"

   # 7. Hapus total file backup di host (Disk host tetap bersih 0 MB)
   log "Menghapus folder backup lokal di host server..."
   rm -rf "$HOST_BACKUP_DIR"
   rm -rf "${BASE_DIR}/backups"/* || true

   # 8. Hapus total file backup di container Docker (Disk container tetap bersih 0 MB)
   log "Membersihkan seluruh file backup di dalam container Docker..."
   docker exec "$CONTAINER_ID" bash -c "rm -rf ${CONTAINER_BACKUP_PATH}/*" || true

   # 9. Pembersihan arsip Google Drive lama (> 30 hari)
   log "Membersihkan backup Google Drive yang lebih lama dari ${RETENTION_DAYS_GDRIVE} hari..."
   rclone delete --min-age "${RETENTION_DAYS_GDRIVE}d" "${RCLONE_REMOTE}" || true

   log "Seluruh alur backup HRMS selesai dengan sukses!"
   log "========================================================"
   ```

3. Simpan file (`Ctrl + O`, `Enter`, `Ctrl + X`).

4. Berikan izin eksekusi:
   ```bash
   chmod +x ~/backup_hrms/backup_hrms_gdrive.sh
   ```

5. Uji coba manual:
   ```bash
   /home/ubuntu/backup_hrms/backup_hrms_gdrive.sh
   ```

---

## 3. Pasang Jadwal Crontab (Jam 12 Siang & Jam 12 Malam WIB)

1. Buka konfigurasi crontab:
   ```bash
   crontab -e
   ```

2. Tambahkan konfigurasi berikut di baris paling bawah:
   ```cron
   # Set zona waktu Crontab ke Waktu Indonesia Barat (WIB)
   CRON_TZ=Asia/Jakarta

   # Jalankan backup otomatis setiap jam 12:00 siang dan 00:00 malam WIB
   0 0,12 * * * /home/ubuntu/backup_hrms/backup_hrms_gdrive.sh
   ```

3. Simpan dan keluar (`Ctrl + O`, `Enter`, `Ctrl + X`).

---

## 4. Monitoring & Maintenance

- **Cek riwayat log backup:**
  ```bash
  cat ~/backup_hrms/backup.log
  # atau memantau secara realtime:
  tail -f ~/backup_hrms/backup.log
  ```
- **Cek isi backup di Google Drive:**
  ```bash
  rclone ls gdrive:Backups_HRMS
  ```
- **Optimasi Swap Server (jika swap penuh):**
  ```bash
  # Reset swap ke RAM:
  sudo swapoff -a && sudo swapon -a

  # Turunkan swappiness ke 10 agar RAM fisik lebih diprioritaskan:
  sudo sysctl vm.swappiness=10
  echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
  ```
