# MikroTik -scripts
моя скромная попытка в код routeros

# шаблон шидулера
#replace the script name in run this command in the terminal
/system scheduler add name="<SCRIPTNAME>" policy=read,write,policy,test on-event="/system script run <SCRIPTNAME>" interval=10m comment="Whyborn77 mikrotik scripts"

# routeros_bkp.sh — бэкап конфигурации MikroTik по SSH.

# firmware_dwn.sh - MikroTik RouterOS Auto-Updater
Bash-скрипт для автоматического скачивания обновлений RouterOS с официального
сайта MikroTik и загрузки их на устройство. Поддерживает политику хранения
«текущая + N предыдущих версий», не тратит трафик на повторную заливку
существующих файлов и чистит устаревшие пакеты и локально, и на самом MikroTik.

## Возможности
- Определение текущей версии RouterOS на устройстве по SSH.
- Скачивание основного NPK и ZIP с extra-пакетами с `download.mikrotik.com`.
- Распаковка extra-пакетов локально.
- Политика хранения по версиям: `KEEP_PREV_VERSIONS` (0 = только текущая,
  1 = текущая + одна предыдущая, и т.д.).
- Загрузка на MikroTik **только отсутствующих** файлов — проверка через
  FTP HEAD + `Content-Length` (RouterOS не поддерживает `SIZE`/`DELE`
  через `curl -Q`).
- Очистка устаревших NPK на самом MikroTik через SSH (`/file remove`).
- Поддержка нескольких архитектур (`arm`, `mipsbe`, …).
- Работа со старыми RouterOS: совместимые SSH KEX/cipher опции.
- Устойчивость к смене SSH-хост-ключа (`UserKnownHostsFile=/dev/null`).
- Логирование всех действий в `update_log.txt`.

## Требования
- Debian/Ubuntu (проверено на OMV/Debian).
- Пакеты:

  ```bash
  apt install sshpass curl unzip

## Пользователь MikroTik с правами на:
- SSH: чтение /system resource
- FTP: запись в MIKROTIK_TARGET_PATH
- SSH: удаление файлов в MIKROTIK_TARGET_PATH.
