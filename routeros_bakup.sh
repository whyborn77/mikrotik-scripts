#!/bin/sh

routername=$1
sshhost=$2
sshport=$3
sshuser="<USERNAME>"
sshpassword="<STRONGPASSWORD>"

# Единая переменная пути
backup_root="/mnt/md0/backup/mikrotiks"
localpath="$backup_root/$sshhost/$routername"

# Создаем директории без вывода ошибок
mkdir -p "$localpath/history" 2>/dev/null
cd "$localpath" || exit 1

precedent_export_name="$routername-config-export-precedent.rsc"
current_export_name="$routername-config-export-current.rsc"
current_backup_name="$routername-config-backup-current.backup"
diff_export_name="$routername-config-export-diff.rsc"

timestamp=$(date +%Y-%m-%d-%H-%M)
current_export_name_history="$routername-$timestamp-config-export-current.rsc"
current_backup_name_history="$routername-$timestamp-config-backup-current.backup"
diff_export_name_history="$routername-$timestamp-config-export-diff.rsc"

# Получаем текущий экспорт конфигурации
if ! sshpass -p "$sshpassword" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$sshuser@$sshhost" -p "$sshport" export >"$current_export_name" 2>/dev/null; then
    echo "Failed to connect to $routername ($sshhost:$sshport)"
    exit 1
fi

# Сравниваем с предыдущей версией
if [ -f "$precedent_export_name" ]; then
    diff -I "RouterOS" "$current_export_name" "$precedent_export_name" >"$diff_export_name" 2>/dev/null
    diff_exit_code=$?
else
    diff_exit_code=1
fi

if [ "$diff_exit_code" -ne 0 ]; then
    # Если есть изменения, создаем и скачиваем бинарный бэкап
    if ! sshpass -p "$sshpassword" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 "$sshuser@$sshhost" -p "$sshport" system backup save name="$current_backup_name" 2>/dev/null; then
        echo "Failed to create backup on $routername"
        exit 1
    fi
    
    if ! sshpass -p "$sshpassword" sftp -o StrictHostKeyChecking=no -oPort="$sshport" -o ConnectTimeout=30 "$sshuser@$sshhost:$current_backup_name" 2>/dev/null; then
        echo "Failed to download backup from $routername"
        exit 1
    fi

    # Сохраняем копии в историю
    cp "$current_export_name" "$localpath/history/$current_export_name_history" 2>/dev/null
    cp "$current_backup_name" "$localpath/history/$current_backup_name_history" 2>/dev/null
    [ -f "$diff_export_name" ] && mv "$diff_export_name" "$localpath/history/$diff_export_name_history" 2>/dev/null
fi

# Актуализируем прецедент и чистим временный diff
mv -f "$current_export_name" "$precedent_export_name" 2>/dev/null
rm -f "$diff_export_name" 2>/dev/null

# БЕЗОПАСНАЯ ОЧИСТКА: Ищем файлы старше 180 дней ТОЛЬКО внутри директорий history
find "$backup_root" -type d -name "history" 2>/dev/null | while read -r history_dir; do
    find "$history_dir" -type f -mtime +180 2>/dev/null | while read -r file; do
        # Извлекаем день месяца и удаляем ведущий ноль (01 -> 1) для корректного сравнения в shell
        file_day=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1 | cut -d'-' -f3 | sed 's/^0//')
        
        if [ "$file_day" = "1" ] || [ "$file_day" = "15" ]; then
            echo "Keeping $file (created on $file_day-th)"
        else
            rm -f "$file"
            echo "Deleted old backup: $file"
        fi
    done
done

exit 0
