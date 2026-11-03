#!/bin/bash
###############################################################################
# НАЗНАЧЕНИЕ: Автоматическое скачивание и загрузка обновлений RouterOS на MikroTik.
#
# РАБОТА СКРИПТА (порядок важен):
#   1. Опрашивает MikroTik по SSH, узнаёт текущую версию ПО.
#   2. ЛОКАЛЬНО: скачивает основной NPK и ZIP с extra-пакетами.
#   3. ЛОКАЛЬНО: распаковывает архив.
#   4. ЛОКАЛЬНО: чистит каталог — оставляет текущую версию + KEEP_PREV_VERSIONS
#      предыдущих (по версии в имени файла, не по mtime).
#   5. Загрузка на MikroTik ТОЛЬКО отсутствующих файлов.
#      Проверка наличия: curl -sI + заголовок Content-Length (RouterOS не
#      поддерживает FTP SIZE/DELE через -Q — проверено, exit 21).
#   6. (Опционально) Та же политика хранения применяется на MikroTik.
#      ВНИМАНИЕ: удаление через FTP DELE на RouterOS 7.25 не работает —
#      используется SSH /file remove.
#   7. Пишет историю в update_log.txt.
#
# ПОЛИТИКА ХРАНЕНИЯ:
#   KEEP_PREV_VERSIONS=1  -> текущая (7.25) + одна предыдущая (7.24.5)
#   KEEP_PREV_VERSIONS=2  -> 7.25, 7.24.5, 7.24.4
#   KEEP_PREV_VERSIONS=0  -> только текущая
#
# ТРЕБОВАНИЯ: apt install sshpass curl unzip; chmod 700 updater.sh
#
# CRON:
#   0 3 * * * /path/to/updater.sh >> /var/log/mikrotik-updater.cron 2>&1
#
# ЭКСПЛУАТАЦИОННЫЕ ЗАМЕТКИ:
# - Наличие файла: curl -sI → Content-Length. SIZE/-Q не работает на RouterOS.
# - Удаление на MikroTik: SSH /file remove [find where name="..."],
#   т.к. FTP DELE на RouterOS 7.x через curl -Q не проходит.
# - Пароль в открытом виде: для внутренней сети приемлемо; при ужесточении
#   требований — вынести в файл с chmod 600 или ~/.pgpass-механизм.
###############################################################################

# ============================ Конфигурация ==================================
MIKROTIK_IP=""
MIKROTIK_USER="user"
MIKROTIK_PASSWORD="password"
MIKROTIK_TARGET_PATH=""
ARCHITECTURE=("arm" "mipsbe")
CURRENT_DIR=""
LOG_FILE="$CURRENT_DIR/update_log.txt"

KEEP_PREV_VERSIONS=1
CLEAN_REMOTE_OLD=1

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
    -o HostKeyAlgorithms=+ssh-rsa
    -o PubkeyAcceptedAlgorithms=+ssh-rsa
    -o Ciphers=+aes128-cbc,3des-cbc
)
# ============================================================================

mkdir -p "$CURRENT_DIR"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

get_mikrotik_version() {
    sshpass -p "$MIKROTIK_PASSWORD" ssh "${SSH_OPTS[@]}" \
        "$MIKROTIK_USER@$MIKROTIK_IP" \
        ':put [/system resource get version]' 2>&1 \
        | tr -d '\r' \
        | awk 'NF{print $1; exit}'
}

# Список всех файлов в MIKROTIK_TARGET_PATH (имена — последний столбец LIST)
list_mikrotik_files() {
    curl -sS -u "$MIKROTIK_USER:$MIKROTIK_PASSWORD" \
        "ftp://$MIKROTIK_IP$MIKROTIK_TARGET_PATH/" 2>/dev/null \
        | awk '{print $NF}' \
        | grep -vE '^\.?$' || true
}

list_mikrotik_npk() {
    list_mikrotik_files | grep -E '\.npk$' || true
}

# Проверка существования: HEAD + Content-Length (SIZE/-Q на RouterOS не работает)
check_mikrotik_file_exists() {
    local filename=$1
    local headers
    headers=$(curl -sI -u "$MIKROTIK_USER:$MIKROTIK_PASSWORD" \
        "ftp://$MIKROTIK_IP$MIKROTIK_TARGET_PATH/$filename" 2>/dev/null)
    [ $? -eq 0 ] || return 1
    echo "$headers" | grep -qi '^Content-Length:'
}

upload_to_mikrotik_ftp() {
    local file=$1
    local base; base=$(basename "$file")
    if check_mikrotik_file_exists "$base"; then
        log "  skip upload (already exists): $base"
        return 0
    fi
    curl -sS --ftp-create-dirs -T "$file" \
        -u "$MIKROTIK_USER:$MIKROTIK_PASSWORD" \
        "ftp://$MIKROTIK_IP$MIKROTIK_TARGET_PATH/"
}

# Удаление на MikroTik через SSH (FTP DELE на RouterOS 7.x через curl -Q не работает)
delete_mikrotik_file() {
    local filename=$1
    sshpass -p "$MIKROTIK_PASSWORD" ssh "${SSH_OPTS[@]}" \
        "$MIKROTIK_USER@$MIKROTIK_IP" \
        "/file remove [find where name=\"$filename\"]" >/dev/null 2>&1
}

extract_version() {
    local fname=$1 arch=$2
    case "$fname" in
        all_packages-*-*.zip)
            echo "$fname" | sed -E 's/^all_packages-[^-]+-(.+)\.zip$/\1/'
            ;;
        *-"$arch".npk)
            echo "$fname" | sed -E 's/^.+-(.+)-'"$arch"'\.npk$/\1/'
            ;;
        *)
            echo ""
            ;;
    esac
}

compute_keep_versions() {
    local current=$1
    local all older keep_prev=""
    all=$(sort -uV)
    older=$(echo "$all" | grep -Fxv "$current" || true)
    if [ "$KEEP_PREV_VERSIONS" -gt 0 ] && [ -n "$older" ]; then
        keep_prev=$(echo "$older" | tail -n "$KEEP_PREV_VERSIONS")
    fi
    { echo "$current"; [ -n "$keep_prev" ] && echo "$keep_prev"; } | sort -uV
}

cleanup_local() {
    local arch_dir=$1 version=$2 arch=$3
    local versions
    versions=$(find "$arch_dir" -maxdepth 1 -type f \
        \( -name "*-$arch.npk" -o -name "all_packages-$arch-*.zip" \) \
        -printf '%f\n' \
        | while IFS= read -r fn; do extract_version "$fn" "$arch"; done \
        | grep -E '^[0-9]+(\.[0-9]+)+$' || true)

    if [ -z "$versions" ]; then
        log "local cleanup [$arch]: no versions detected, skip"
        return
    fi

    local keep_list
    keep_list=$(echo "$versions" | compute_keep_versions "$version")
    log "local cleanup [$arch]: keep versions: $(echo $keep_list | tr '\n' ' ')"

    local deleted=0 kept=0
    while IFS= read -r -d '' f; do
        local base; base=$(basename "$f")
        local fver; fver=$(extract_version "$base" "$arch")
        if [ -z "$fver" ]; then kept=$((kept+1)); continue; fi
        local keep=0
        while IFS= read -r kv; do
            [ "$kv" = "$fver" ] && { keep=1; break; }
        done <<< "$keep_list"
        if [ "$keep" = "1" ]; then kept=$((kept+1)); continue; fi
        log "  deleting local [$arch]: $base (version $fver)"
        rm -f -- "$f" && deleted=$((deleted+1))
    done < <(find "$arch_dir" -maxdepth 1 -type f -print0)

    log "local cleanup [$arch] done: removed=$deleted kept=$kept"
}

cleanup_remote() {
    local version=$1
    log "remote cleanup: policy keep=$version + $KEEP_PREV_VERSIONS prev, path=$MIKROTIK_TARGET_PATH"

    local all_files
    all_files=$(list_mikrotik_npk)
    if [ -z "$all_files" ]; then
        log "remote cleanup: no .npk files found, skip"
        return
    fi

    for arch in "${ARCHITECTURE[@]}"; do
        local versions
        versions=$(echo "$all_files" \
            | grep -E -- "-$arch\.npk$" \
            | while IFS= read -r fn; do extract_version "$fn" "$arch"; done \
            | grep -E '^[0-9]+(\.[0-9]+)+$' || true)

        if [ -z "$versions" ]; then
            log "remote cleanup [$arch]: no versions detected, skip"
            continue
        fi

        local keep_list
        keep_list=$(echo "$versions" | compute_keep_versions "$version")
        log "remote cleanup [$arch]: keep versions: $(echo $keep_list | tr '\n' ' ')"

        local deleted=0
        while IFS= read -r fname; do
            [ -z "$fname" ] && continue
            case "$fname" in *-"$arch".npk) : ;; *) continue ;; esac
            local fver; fver=$(extract_version "$fname" "$arch")
            [ -z "$fver" ] && continue
            local keep=0
            while IFS= read -r kv; do
                [ "$kv" = "$fver" ] && { keep=1; break; }
            done <<< "$keep_list"
            [ "$keep" = "1" ] && continue
            if delete_mikrotik_file "$fname"; then
                log "  deleting remote [$arch]: $fname (version $fver)"
                deleted=$((deleted+1))
            else
                log "  warning: failed to delete remote [$arch]: $fname"
            fi
        done <<< "$all_files"

        log "remote cleanup [$arch] done: removed=$deleted"
    done
}

# ================================ main ======================================

MIKROTIK_VERSION=$(get_mikrotik_version)
if [ -z "$MIKROTIK_VERSION" ]; then
    log "error: unable to retrieve version from MikroTik"
    exit 1
fi
log "MicroTik version: $MIKROTIK_VERSION"
log "retention policy: keep current + $KEEP_PREV_VERSIONS previous version(s)"

# ---------- ФАЗА 1: ЛОКАЛЬНО ----------
for arch in "${ARCHITECTURE[@]}"; do
    ARCH_DIR="$CURRENT_DIR/$arch"
    mkdir -p "$ARCH_DIR"

    EXTRA_ZIP_FILE="$ARCH_DIR/all_packages-$arch-$MIKROTIK_VERSION.zip"
    MAIN_NPK_FILE="$ARCH_DIR/routeros-$MIKROTIK_VERSION-$arch.npk"

    if [ ! -f "$EXTRA_ZIP_FILE" ]; then
        EXTRA_ZIP_URL="https://download.mikrotik.com/routeros/$MIKROTIK_VERSION/all_packages-$arch-$MIKROTIK_VERSION.zip"
        log "downloading extra packages from $EXTRA_ZIP_URL"
        if curl -fsS -o "$EXTRA_ZIP_FILE" "$EXTRA_ZIP_URL"; then
            log "unzipping extra packages to $ARCH_DIR"
            unzip -q -o "$EXTRA_ZIP_FILE" -d "$ARCH_DIR"
            rm -f "$ARCH_DIR/routeros-$MIKROTIK_VERSION-$arch.npk" 2>/dev/null
        else
            log "error: failed to download extra packages for $arch"
            rm -f "$EXTRA_ZIP_FILE"
            exit 1
        fi
    else
        log "extra packages for $arch already exist. Skipping download."
    fi

    if [ ! -f "$MAIN_NPK_FILE" ]; then
        MAIN_NPK_URL="https://download.mikrotik.com/routeros/$MIKROTIK_VERSION/routeros-$MIKROTIK_VERSION-$arch.npk"
        log "downloading main package from $MAIN_NPK_URL"
        if ! curl -fsS -o "$MAIN_NPK_FILE" "$MAIN_NPK_URL"; then
            log "error: failed to download main package for $arch"
            rm -f "$MAIN_NPK_FILE"
            exit 1
        fi
    else
        log "main package $MAIN_NPK_FILE already exists. Skipping download."
    fi

    cleanup_local "$ARCH_DIR" "$MIKROTIK_VERSION" "$arch"
done

# ---------- ФАЗА 2: ЗАГРУЗКА ТОЛЬКО ОТСУТСТВУЮЩИХ ----------
for arch in "${ARCHITECTURE[@]}"; do
    ARCH_DIR="$CURRENT_DIR/$arch"
    MAIN_NPK_FILE="$ARCH_DIR/routeros-$MIKROTIK_VERSION-$arch.npk"

    MAIN_FILENAME=$(basename "$MAIN_NPK_FILE")
    if check_mikrotik_file_exists "$MAIN_FILENAME"; then
        log "main package $MAIN_FILENAME already exists on MikroTik. Skipping upload."
    else
        log "uploading main package to MikroTik: $MAIN_NPK_FILE"
        if upload_to_mikrotik_ftp "$MAIN_NPK_FILE"; then
            log "main package uploaded successfully"
        else
            log "error: failed to upload main package"
        fi
    fi

    log "checking extra npk files on MikroTik [$arch]..."
    uploaded=0
    skipped=0
    for file in "$ARCH_DIR"/*.npk; do
        [ -f "$file" ] || continue
        [ "$file" = "$MAIN_NPK_FILE" ] && continue
        EXTRA_FILENAME=$(basename "$file")
        if check_mikrotik_file_exists "$EXTRA_FILENAME"; then
            skipped=$((skipped+1))
        else
            log "uploading $file"
            if upload_to_mikrotik_ftp "$file"; then
                log "upload successful: $EXTRA_FILENAME"
                uploaded=$((uploaded+1))
            else
                log "error: failed to upload $EXTRA_FILENAME"
            fi
        fi
    done
    log "extra npk upload [$arch] done: uploaded=$uploaded skipped=$skipped"
done

# ---------- ФАЗА 3: УДАЛЁННАЯ ОЧИСТКА (через SSH) ----------
if [ "$CLEAN_REMOTE_OLD" = "1" ]; then
    cleanup_remote "$MIKROTIK_VERSION"
fi

log "update completed successfully"
