# v2.0
# делать на внешнем пк или контейнере где есть sshpass curl scp unzip
# проверяет версию через ssh затем скачивает main и распаковывает extra у себя и закачивает на микрот в указанную папку (для капсман) после чего подчищает у себя zip npk. Есть проверка на версию, не тратит трафик если версия не менялась.
# >npk-fw_uploader.sh
# chmod +x npk-fw_uploader.sh
# Конфигурация
#!/bin/bash

# Конфигурация
MIKROTIK_IP=""   # IP-адрес MikroTik
MIKROTIK_USER=""        # Имя пользователя MikroTik
MIKROTIK_PASSWORD="" # Пароль пользователя MikroTik
MIKROTIK_TARGET_PATH="/sata3/caps"
ARCHITECTURE=("arm" "mipsbe") # Архитектуры
CURRENT_DIR= # Текущая директория
LOG_FILE="$CURRENT_DIR/update_log.txt" # Файл для логирования

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Безопасное получение версии без grep и сложных кавычек
get_mikrotik_version() {
    sshpass -p "$MIKROTIK_PASSWORD" ssh -o StrictHostKeyChecking=no "$MIKROTIK_USER@$MIKROTIK_IP" \
        ':put [/system resource get version]' 2>/dev/null | tr -d '\r' | cut -d' ' -f1
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

log "MikroTik version: $MIKROTIK_VERSION"

for arch in "${ARCHITECTURE[@]}"; do
    ARCH_DIR="$CURRENT_DIR/$arch"
    mkdir -p "$ARCH_DIR"

    EXTRA_ZIP_FILE="$ARCH_DIR/all_packages-$arch-$MIKROTIK_VERSION.zip"
    MAIN_NPK_FILE="$ARCH_DIR/routeros-$MIKROTIK_VERSION-$arch.npk"

    # 1. Проверка и скачивание extra-пакетов
    if [ ! -f "$EXTRA_ZIP_FILE" ] || [ -z "$(find "$ARCH_DIR" -maxdepth 1 -name "*.npk" ! -name "routeros-*" 2>/dev/null)" ]; then
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

    # 3. Загрузка основного пакета
    log "uploading main package to MikroTik: $MAIN_NPK_FILE"
    if upload_to_mikrotik_ftp "$MAIN_NPK_FILE"; then
        log "main package uploaded successfully"
    else
        log "error: failed to upload main package"
    fi

    # 4. Загрузка дополнительных пакетов
    log "uploading extra npk files to MikroTik..."
    for file in "$ARCH_DIR"/*.npk; do
        if [ -f "$file" ] && [ "$file" != "$MAIN_NPK_FILE" ]; then
            log "uploading $file"
            if upload_to_mikrotik_ftp "$file"; then
                log "upload successful: $(basename "$file")"
            else
                log "error: failed to upload $(basename "$file")"
            fi
        fi
    done

    # 5. Очистка старых версий
    log "cleaning up old versions for $arch..."
    find "$ARCH_DIR" -type f ! -name "*$MIKROTIK_VERSION*" -delete

done

log "update completed successfully"
