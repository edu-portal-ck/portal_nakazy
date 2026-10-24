#!/usr/bin/env bash
# Перше встановлення «Реєстру наказів» на чистому сервері (Debian / Ubuntu та подібні).
# Запуск:  sudo ./install.sh        (інший порт:  sudo HTTP_PORT=8080 ./install.sh)
set -eu
cd "$(dirname "$0")"

if [ "$(id -u)" -ne 0 ] && ! docker info >/dev/null 2>&1; then
  echo "Запустіть від root: sudo ./install.sh"; exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "1/3 Docker не знайдено, встановлюю (потрібен інтернет)..."
  apt-get update
  apt-get install -y ca-certificates curl
  curl -fsSL https://get.docker.com | sh
else
  echo "1/3 Docker вже встановлено"
fi
docker compose version >/dev/null 2>&1 || { echo "Немає плагіна 'docker compose'. Встановіть docker-compose-plugin."; exit 1; }
command -v curl >/dev/null 2>&1 || apt-get install -y -qq curl >/dev/null 2>&1 || true   # для перевірки, що програма відповідає

if [ -n "${HTTP_PORT:-}" ] && [ ! -f .env ]; then echo "HTTP_PORT=$HTTP_PORT" > .env; fi
[ -f .env ] && sed -i 's/\r$//' .env   # .env, збережений у Windows (CRLF), ламає шляхи — прибираємо \r
[ -f .env ] && set -a && . ./.env && set +a

# Нова установка (бази ще немає) і пароль не задано: генеруємо випадковий замість стандартного «admin»
NEW_PW=""
FRESH=0; [ -f data/orders.db ] || FRESH=1
if [ ! -f data/orders.db ] && [ -z "${INITIAL_ADMIN_PASSWORD:-}" ]; then
  NEW_PW=$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 12 || true)
  printf '\n# Пароль початкового адміністратора (згенеровано install.sh; діє лише для порожньої бази)\nINITIAL_ADMIN_PASSWORD=%s\n' "$NEW_PW" >> .env
  INITIAL_ADMIN_PASSWORD="$NEW_PW"; export INITIAL_ADMIN_PASSWORD
fi
[ -f .env ] && chmod 600 .env

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
HTTPS_ON=0
case "${COMPOSE_FILE:-}" in *https*) HTTPS_ON=1 ;; esac
PORT="${HTTP_PORT:-80}"
CHECK="http://localhost:$PORT/api/meta"
[ "$HTTPS_ON" = 1 ] && CHECK="http://127.0.0.1:8000/api/meta"

echo "2/3 Збірка і запуск (перший раз кілька хвилин)..."
mkdir -p data
docker compose up -d --build

echo "3/3 Перевірка..."
for i in $(seq 1 60); do
  if curl -fsS "$CHECK" >/dev/null 2>&1; then
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo
    if [ "$HTTPS_ON" = 1 ]; then
      HP="${HTTPS_PORT:-443}"
      URL="https://${SITE_ADDRESS}"; [ "$HP" != "443" ] && URL="$URL:$HP"
      CA="http://${SITE_ADDRESS}"; [ "$PORT" != "80" ] && CA="$CA:$PORT"
      echo "Готово. Відкрийте у браузері: $URL"
      echo "Сертифікат для першого комп'ютера (діє лише до зміни початкового пароля адміністратора): $CA/nakazy-ca.crt"
      echo "Далі сертифікат видає адміністратор: Адміністрування -> Налаштування -> Сертифікат HTTPS (README, розділ «HTTPS»)."
    else
      URL="http://${IP:-IP-сервера}"; [ "$PORT" != "80" ] && URL="$URL:$PORT"
      echo "Готово. Відкрийте у браузері: $URL"
    fi
    if [ "$FRESH" = 0 ]; then
      echo "Вхід: наявні дані збережено — входьте своїми паролями."
    else
      echo "Вхід: «Увійти» -> Адміністратор, пароль: ${INITIAL_ADMIN_PASSWORD:-admin}"
      [ -n "$NEW_PW" ] && echo "(пароль згенеровано й збережено у файлі .env)"
      echo "Після входу одразу змініть пароль на свій."
    fi
    exit 0
  fi
  sleep 1
done
echo "Програма не відповіла. Подивіться журнал: docker compose logs --tail 50"; exit 1
