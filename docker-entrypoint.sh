#!/bin/sh
# Запуск у контейнері: папка /data передається користувачу app (uid 1000), далі програма працює вже не від root.
set -e
if [ "$(id -u)" = "0" ]; then
  mkdir -p /data
  # власника міняємо лише тоді, коли є чужі файли (перший запуск на даних старої версії або після ручних команд від root)
  if [ -n "$(find /data -xdev ! -user 1000 -print -quit 2>/dev/null)" ]; then
    echo "Передаю папку /data користувачу app..."
    chown -R 1000:1000 /data
  fi
  exec setpriv --reuid=1000 --regid=1000 --init-groups "$@"
fi
exec "$@"
