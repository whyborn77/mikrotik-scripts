#!/bin/bash
###############################################################################
# НАЗНАЧЕНИЕ: Автоматическое скачивание и загрузка обновлений RouterOS на MikroTik.
#
# РАБОТА СКРИПТА:
# 1. Опрашивает MikroTik по SSH, узнает текущую версию ПО.
# 2. Скачивает основной NPK и ZIP с extra-пакетами с download.mikrotik.com.
# 3. Распаковывает архив, загружает все NPK на устройство через FTP.
# 4. Очищает локальный каталог от старых версий файлов.
# 5. Пишет историю действий в update_log.txt.
#
# ТРЕБОВАНИЯ И ЗАПУСК (Debian):
# 1. Зависимости: apt install sshpass curl unzip
# 2. Редактирование: mcedit updater.sh (заполнить блок "Конфигурация" ниже)
# 3. Права: chmod 700 updater.sh
# 4. Запуск: ./updater.sh
###############################################################################

# Конфигурация
MIKROTIK_IP=""
MIKROTIK_USER=""
MIKROTIK_PASSWORD=""
MIKROTIK_TARGET_PATH="/sata3/caps"
ARCHITECTURE=("arm" "mipsbe")
CURRENT_DIR="/mnt/md0/backup/mikrotiks/npk-download"
LOG_FILE="$CURRENT_DIR/update_log.txt"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Безопасное получение версии без grep и сложных кавычек
get_mikrotik_version() {
    sshpass -p "$MIKROTIK_PASSWORD" ssh -o StrictHostKeyChecking=no "$MIKROTIK_USER@$MIKROTIK_IP" \
        ':put [/system resource get version]' 2>/dev/null | tr -d '\r' | cut -d' ' -f1
}

# Проверка существования файла на MikroTik через FTP
check_mikrotik_file_exists() {
    local filename=$1
    curl -sI -u "$MIKROTIK_USER:$MIKROTIK_PASSWORD" "ftp://$MIKROTIK_IP$MIKROTIK_TARGET_PATH/$filename" >/dev/null 2>&1
}

upload_to_mikrotik_ftp() {
    local file=$1
    curl -sS -T "$file" -u "$MIKROTIK_USER:$MIKROTIK_PASSWORD" "ftp://$MIKROTIK_IP$MIKROTIK_TARGET_PATH/"
}

MIKROTIK_VERSION=$(get_mikrotik_version)
if [ -z "$MIKROTIK_VERSION" ]; then
    log "error: unable to retrieve version from MikroTik"
    exit 1
fi

log "MicroTik version: $MIKROTIK_VERSION"

for arch in "${ARCHITECTURE[@]}"; do
    ARCH_DIR="$CURRENT_DIR/$arch"
    mkdir -p "$ARCH_DIR"

    EXTRA_ZIP_FILE="$ARCH_DIR/all_packages-$arch-$MIKROTIK_VERSION.zip"
    MAIN_NPK_FILE="$ARCH_DIR/routeros-$MIKROTIK_VERSION-$arch.npk"

    # 1. Проверка и скачивание extra-пакетов
    if [ ! -f "$EXTRA_ZIP_FILE" ]; then
        EXTRA_ZIP_URL="https://download.mikrotik.com/routeros/$MIKROTIK_VERSION/all_packages-$arch-$MIKROTIK_VERSION.zip"
        log "downloading extra packages from $EXTRA_ZIP_URL"
        
        if curl -sS -o "$EXTRA_ZIP_FILE" "$EXTRA_ZIP_URL"; then
            log "unzipping extra packages to $ARCH_DIR"
            unzip -q -o "$EXTRA_ZIP_FILE" -d "$ARCH_DIR"
            rm -f "$ARCH_DIR/routeros-$MIKROTIK_VERSION-$arch.npk" 2>/dev/null
        else
            log "error: failed to download extra packages for $arch"
            exit 1
        fi
    else
        log "extra packages for $arch already exist. Skipping download."
    fi

    # 2. Проверка и скачивание основного пакета
    if [ ! -f "$MAIN_NPK_FILE" ]; then
        MAIN_NPK_URL="https://download.mikrotik.com/routeros/$MIKROTIK_VERSION/routeros-$MIKROTIK_VERSION-$arch.npk"
        log "downloading main package from $MAIN_NPK_URL"
        if ! curl -sS -o "$MAIN_NPK_FILE" "$MAIN_NPK_URL"; then
            log "error: failed to download main package for $arch"
            exit 1
        fi
    else
        log "main package $MAIN_NPK_FILE already exists. Skipping download."
    fi

    # 3. Загрузка основного пакета с проверкой дубликатов
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

    # 4. Загрузка дополнительных пакетов с проверкой дубликатов
    log "uploading extra npk files to MikroTik..."
    for file in "$ARCH_DIR"/*.npk; do
        if [ -f "$file" ] && [ "$file" != "$MAIN_NPK_FILE" ]; then
            EXTRA_FILENAME=$(basename "$file")
            if check_mikrotik_file_exists "$EXTRA_FILENAME"; then
                log "file $EXTRA_FILENAME already exists on MikroTik. Skipping upload."
            else
                log "uploading $file"
                if upload_to_mikrotik_ftp "$file"; then
                    log "upload successful: $EXTRA_FILENAME"
                else
                    log "error: failed to upload $EXTRA_FILENAME"
                fi
            fi
        fi
    done

    # 5. Очистка старых версий
    log "cleaning up old versions for $arch..."
    find "$ARCH_DIR" -type f \( -name "all_packages-*" -o -name "routeros-*" \) ! -name "*$MIKROTIK_VERSION*" -delete

done

log "update completed successfully"
