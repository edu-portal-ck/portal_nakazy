#!/usr/bin/env bash
# Безпечне оновлення реєстру наказів: збірка -> копія даних -> запуск -> перевірка -> відкат при помилці.
# Використання: розпакуйте новий nakazy.zip поверх папки програми, потім:  ./update.sh
set -u
cd "$(dirname "$0")"
[ -f .env ] && sed -i 's/\r$//' .env   # .env, збережений у Windows (CRLF), ламає шляхи — прибираємо \r
[ -f .env ] && set -a && . ./.env && set +a
# HTTPS (docker-compose.https.yml) використовує «!override» — потрібен Docker Compose 2.24 або новіший
case "${COMPOSE_FILE:-}" in *https*)
  CV=$(docker compose version --short 2>/dev/null | sed 's/^v//'); CMAJ=${CV%%.*}; CMIN=$(echo "$CV" | cut -d. -f2)
  case "$CMAJ$CMIN" in *[!0-9]*|"") CMAJ=0; CMIN=0 ;; esac
  if [ "$CMAJ" -lt 2 ] || { [ "$CMAJ" -eq 2 ] && [ "$CMIN" -lt 24 ]; }; then
    echo "Для HTTPS потрібен Docker Compose 2.24 або новіший, а встановлено ${CV:-невідомо яку версію}."
    echo "Оновіть Docker (потрібен інтернет):  curl -fsSL https://get.docker.com | sh   — і запустіть цей скрипт ще раз."
    exit 1
  fi ;;
esac
PORT="${HTTP_PORT:-80}"
CHECK="http://localhost:$PORT/api/meta"
case "${COMPOSE_FILE:-}" in *https*) CHECK="http://127.0.0.1:8000/api/meta" ;; esac   # з HTTPS програма напряму доступна лише локально
command -v curl >/dev/null 2>&1 || apt-get install -y -qq curl >/dev/null 2>&1
mkdir -p data backups

STAMP=$(date +%Y-%m-%d_%H%M%S)
# образ програми, що працює зараз, — зберігаємо під ім'ям :prev, щоб при невдачі повернутися на нього
IMG=$(docker compose config --images 2>/dev/null | grep -v caddy | head -1)
PREV=""
if [ -n "$IMG" ] && docker image inspect "$IMG" >/dev/null 2>&1; then
  docker image tag "$IMG" "${IMG%%:*}:prev" && PREV="${IMG%%:*}:prev"
fi

# спершу збірка: програма в цей час працює далі, тож сайт не простоює, поки завантажуються пакети
echo "1/4 Збірка нової версії (програма поки працює)"
docker compose build || { echo "Помилка збірки. Нічого не змінено, працює попередня версія."; exit 1; }

echo "2/4 Копія даних -> backups/data_$STAMP"
# коротка зупинка, щоб копія бази була узгодженою (без записів під час копіювання)
docker compose stop >/dev/null 2>&1 || true
B="backups/data_$STAMP"
mkdir -p "$B"
# база й службові файли — повна копія; скани — жорсткі посилання (миттєво й без витрат місця; файли сканів не змінюються на місці)
( shopt -s nullglob; cd data && for f in *; do [ "$f" = "uploads" ] || [ "$f" = "cache" ] || cp -a "$f" "../$B/"; done )
if [ -d data/uploads ]; then cp -al data/uploads "$B/uploads" 2>/dev/null || cp -a data/uploads "$B/uploads"; fi
[ -f "$B/orders.db" ] || [ ! -f data/orders.db ] || { echo "Не вдалося зробити копію бази, оновлення скасовано"; docker compose start >/dev/null 2>&1; exit 1; }

echo "3/4 Запуск нової версії"
docker compose up -d --remove-orphans || { echo "Не вдалося запустити."; }

echo "4/4 Перевірка (до 2 хвилин: на першому запуску програма може оновлювати базу й права на файли)"
OK=0
for i in $(seq 1 120); do
  if curl -fsS "$CHECK" >/dev/null 2>&1; then OK=1; break; fi
  sleep 1
done

if [ "$OK" -eq 1 ]; then
  echo "Готово: програма працює. Копія даних: backups/data_$STAMP"
  # зберігаємо лише 7 останніх копій
  ls -dt backups/data_* 2>/dev/null | tail -n +8 | xargs -r rm -rf
  # копію в хмару, налаштовану старішою версією (фіксований час), переводимо на керування з програми
  if [ -f /etc/systemd/system/nakazy-backup.service ] && ! grep -q -- "--auto" /etc/systemd/system/nakazy-backup.service; then
    ./backup_gdrive.sh --timer >/dev/null 2>&1 && echo "Копія в хмару: час тепер задається в програмі (Адміністрування → Налаштування)"
  fi
  exit 0
fi

echo "ПОМИЛКА: нова версія не відповідає. Журнал програми:"
docker compose logs --tail 30 nakazy
echo "Повертаю дані й попередню версію..."
docker compose down >/dev/null 2>&1
rm -rf data
cp -a "backups/data_$STAMP" data
mkdir -p data/cache
if [ -n "$PREV" ] && docker image tag "$PREV" "${IMG%%:*}:latest" && docker compose up -d --no-build >/dev/null 2>&1; then
  for i in $(seq 1 60); do curl -fsS "$CHECK" >/dev/null 2>&1 && break; sleep 1; done
  echo "Попередня версія знову працює, дані — як до оновлення. Надішліть журнал вище тому, хто дав вам архів."
else
  echo "Дані відновлено, але попередню версію запустити не вдалося. Розпакуйте попередній nakazy.zip і виконайте ./update.sh"
fi
exit 1
