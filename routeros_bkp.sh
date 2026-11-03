#!/bin/sh
#
# routeros_bkp.sh — бэкап конфигурации MikroTik по SSH.
#
# Использование:
#   ./routeros_bkp.sh <routername> <host> <port>
#
# Что делает:
#   1. Забирает `export` с роутера и сравнивает с предыдущим (diff).
#   2. При изменениях — создаёт бинарный backup на роутере и скачивает его.
#   3. Ведёт историю: current.rsc / .backup / diff.rsc в подкаталоге history.
#   4. Один раз в сутки чистит историю по политике архива (см. ниже).
#      Флаг «уже чистили сегодня»: <script_dir>/.routeros_bkp_cleanup.done
#   5. Пишет лог в <script_dir>/routeros_bkp.log (ротация 5 МБ → .1).
#
# Политика архива (history/):
#   - retention_days=400 — «горячая» зона: всё, что моложе 400 дней,
#     хранится полностью (каждый бэкап, включая .rsc / .backup / diff.rsc).
#   - Файлы старше 400 дней УДАЛЯЮТСЯ, КРОМЕ созданных 1-го или 15-го
#     числа месяца — они сохраняются БЕССРОЧНО (cold-архив, 2 точки/мес).
#   - Итог: ~400 дней плотной истории + вечный «скелет» по 2 точки в месяц.
#   - Чтобы 1/15 тоже удалялись по достижении 400 дней — см. комментарий
#     в блоке «Очистка старых бэкапов».
#
# Настройки:
#   - Логин/пароль SSH — в /etc/routeros_bkp.env (права 600, root).
#   - retention_days и пути — ниже в скрипте.
#
# Требования: sshpass, ssh, sftp, diff, find, stat, mktemp.
# Код возврата: 0 — успех, 1 — ошибка (см. лог).
#

routername=$1
sshhost=$2
sshport=$3

if [ -z "$routername" ] || [ -z "$sshhost" ] || [ -z "$sshport" ]; then
    echo "Usage: $0 <routername> <host> <port>" >&2
    exit 1
fi

# === Каталог скрипта (для лога и флага очистки) ===
script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
script_dir=$(cd "$(dirname "$script_path")" && pwd)

# === Загружаем логин/пароль из защищённого файла ===
ENV_FILE="/etc/routeros_bkp.env"
if [ ! -r "$ENV_FILE" ]; then
    echo "ERROR: cannot read $ENV_FILE (check permissions/ownership)" >&2
    exit 1
fi
. "$ENV_FILE"

: "${SSH_USER:?SSH_USER not set in $ENV_FILE}"
: "${SSH_PASSWORD:?SSH_PASSWORD not set in $ENV_FILE}"

sshuser="$SSH_USER"
sshpassword="$SSH_PASSWORD"

# === Настройки скрипта ===
backup_root="/mnt/md0/backup/mikrotiks"
retention_days=400

# === Логирование (рядом со скриптом) ===
log_file="$script_dir/routeros_bkp.log"
log_max_size=$((5 * 1024 * 1024))

if ! touch "$log_file" 2>/dev/null; then
    echo "ERROR: cannot write $log_file (check permissions on $script_dir)" >&2
    exit 1
fi

if [ -f "$log_file" ]; then
    size=$(stat -c %s "$log_file" 2>/dev/null || echo 0)
    [ "$size" -gt "$log_max_size" ] && mv -f "$log_file" "$log_file.1" 2>/dev/null
fi

log() {
    level="$1"; shift
    msg="$*"
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    line="[$ts] [$level] [$routername@$sshhost:$sshport] $msg"
    printf '%s\n' "$line" >> "$log_file"
    if [ "$level" = "ERROR" ]; then
        printf '%s\n' "$line" >&2
    else
        printf '%s\n' "$line"
    fi
}

log INFO "=== Start backup ==="

localpath="$backup_root/$sshhost/$routername"

if ! mkdir -p "$localpath/history" 2>/dev/null; then
    log ERROR "Cannot create directory $localpath/history"
    exit 1
fi
cd "$localpath" || { log ERROR "Cannot cd to $localpath"; exit 1; }

precedent_export_name="$routername-config-export-precedent.rsc"
current_export_name="$routername-config-export-current.rsc"
current_backup_name="$routername-config-backup-current.backup"
diff_export_name="$routername-config-export-diff.rsc"

timestamp=$(date +%Y-%m-%d-%H-%M)
current_export_name_history="$routername-$timestamp-config-export-current.rsc"
current_backup_name_history="$routername-$timestamp-config-backup-current.backup"
diff_export_name_history="$routername-$timestamp-config-export-diff.rsc"

# --- Получаем текущий экспорт ---
log INFO "Fetching config export via SSH"
if ! sshpass -p "$sshpassword" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$sshuser@$sshhost" -p "$sshport" export >"$current_export_name" 2>/dev/null; then
    log ERROR "Failed to connect to $routername ($sshhost:$sshport)"
    rm -f "$current_export_name"
    exit 1
fi
log INFO "Config export received ($(wc -c < "$current_export_name" 2>/dev/null || echo 0) bytes)"

# --- Сравнение с предыдущим экспортом ---
if [ -f "$precedent_export_name" ]; then
    diff -I "RouterOS" "$current_export_name" "$precedent_export_name" >"$diff_export_name" 2>/dev/null
    diff_exit_code=$?
else
    log INFO "No precedent export found, treating as first run"
    diff_exit_code=1
fi

if [ "$diff_exit_code" -ne 0 ]; then
    log INFO "Configuration changed (or first run) — creating binary backup"

    if ! sshpass -p "$sshpassword" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$sshuser@$sshhost" -p "$sshport" system backup save name="$current_backup_name" 2>/dev/null; then
        log ERROR "Failed to create backup on $routername"
        exit 1
    fi
    log INFO "Binary backup created on router"

    if ! sshpass -p "$sshpassword" sftp -o StrictHostKeyChecking=no -oPort="$sshport" -o ConnectTimeout=30 "$sshuser@$sshhost:$current_backup_name" 2>/dev/null; then
        log ERROR "Failed to download backup from $routername"
        exit 1
    fi
    log INFO "Binary backup downloaded"

    if cp "$current_export_name" "$localpath/history/$current_export_name_history" 2>/dev/null; then
        log INFO "History export saved: $current_export_name_history"
    else
        log WARN "Could not save history export: $current_export_name_history"
    fi

    if cp "$current_backup_name" "$localpath/history/$current_backup_name_history" 2>/dev/null; then
        log INFO "History backup saved: $current_backup_name_history"
    else
        log WARN "Could not save history backup: $current_backup_name_history"
    fi

    if [ -f "$diff_export_name" ]; then
        if mv "$diff_export_name" "$localpath/history/$diff_export_name_history" 2>/dev/null; then
            log INFO "History diff saved: $diff_export_name_history"
        else
            log WARN "Could not save history diff: $diff_export_name_history"
        fi
    fi
else
    log INFO "Configuration unchanged — skipping binary backup"
fi

# --- Актуализируем прецедент ---
mv -f "$current_export_name" "$precedent_export_name" 2>/dev/null
rm -f "$diff_export_name" 2>/dev/null

# --- Очистка старых бэкапов (не чаще раза в сутки) ---
# Политика:
#   - старше retention_days → удалить,
#   - НО файлы от 1-го и 15-го числа сохраняются бессрочно (cold-архив).
# Если нужна строгая граница в retention_days и для 1/15 — замените условие
# на проверку возраста файла, например:
#   file_age_days=$(( ( $(date +%s) - $(stat -c %Y "$file") ) / 86400 ))
#   if { [ "$file_day" = "1" ] || [ "$file_day" = "15" ]; } \
#      && [ "$file_age_days" -le $((retention_days + 30)) ]; then ...
cleanup_flag="$script_dir/.routeros_bkp_cleanup.done"
today=$(date +%Y-%m-%d)

if [ ! -f "$cleanup_flag" ] || [ "$(cat "$cleanup_flag" 2>/dev/null)" != "$today" ]; then
    log INFO "=== Cleanup start (retention=${retention_days}d) ==="

    tmp_counts=$(mktemp) || { log ERROR "mktemp failed"; exit 1; }
    echo "0 0" > "$tmp_counts"

    find "$backup_root" -type d -name "history" 2>/dev/null | while read -r history_dir; do
        find "$history_dir" -type f -mtime +"$retention_days" 2>/dev/null | while read -r file; do
            file_day=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1 | cut -d'-' -f3 | sed 's/^0//')
            read -r d k < "$tmp_counts"
            if [ "$file_day" = "1" ] || [ "$file_day" = "15" ]; then
                echo "$d $((k+1))" > "$tmp_counts"
            else
                if rm -f "$file"; then
                    echo "$((d+1)) $k" > "$tmp_counts"
                    log INFO "Deleted $file"
                else
                    log WARN "Failed to delete $file"
                fi
            fi
        done
    done

    read -r deleted kept < "$tmp_counts"
    rm -f "$tmp_counts"

    log INFO "=== Cleanup finished: deleted=$deleted, kept=$kept ==="

    printf '%s\n' "$today" > "$cleanup_flag" 2>/dev/null
else
    log INFO "Cleanup already done today ($(cat "$cleanup_flag" 2>/dev/null)), skipping"
fi

log INFO "=== Backup finished OK ==="
exit 0
