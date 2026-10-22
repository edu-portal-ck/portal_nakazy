#!/usr/bin/env bash
# Зашифрована резервна копія «Реєстру наказів» у Google Диск (або в будь-яке сховище, яке підтримує rclone).
# Налаштування один раз — README, розділ «Копія в Google Диск».
#
#   ./backup_gdrive.sh --setup               майстер: підключити Google Диск, шифрування, перша копія, розклад
#   ./backup_gdrive.sh                       зробити копію зараз
#   ./backup_gdrive.sh --timer               увімкнути автоматичний запуск (час — у програмі: Адміністрування → Налаштування)
#   ./backup_gdrive.sh --auto                запускає таймер кожні 5 хв: копія за розкладом або на запит із програми
#   ./backup_gdrive.sh --list                які копії бази є в хмарі
#   ./backup_gdrive.sh --restore [РРРР-ММ-ДД]  відновити з хмари (без дати — найновішу)
#
# Що копіюється: база (окремий файл на кожен день, зберігаються BACKUP_KEEP_DAYS днів), скани data/uploads
# (видалені й замінені — ще BACKUP_KEEP_DAYS днів у папці deleted/ДАТА), файл .env і сертифікати HTTPS (caddy/data).
set -u
cd "$(dirname "$0")"
[ -f .env ] && sed -i 's/\r$//' .env   # .env, збережений у Windows (CRLF), ламає шляхи — прибираємо \r
[ -f .env ] && set -a && . ./.env && set +a
export TZ="${TIMEZONE:-Europe/Kyiv}"   # той самий часовий пояс, що й у програмі
REMOTE="${BACKUP_REMOTE:-nakazy-crypt:}"
KEEP="${BACKUP_KEEP_DAYS:-30}"
TODAY=$(date +%F)
# Безпека: папкою data/ керує програма (користувач app). Скрипт працює від root, тому НІКОЛИ не пише у файли data/
# напряму (там могло б опинитися символьне посилання на системний файл). Усе службове root готує у своїй закритій
# папці WORK (поряд, у /opt/nakazy — програма її не бачить) і кладе в data/ атомарною заміною mv: rename(2) замінює
# сам запис у папці, а не те, на що вказує посилання. Власника змінюємо з chown -h (без переходу за посиланням).
WORK="$(pwd)/.backup-work"

work_dir() {
  if [ -L "$WORK" ] || { [ -e "$WORK" ] && [ ! -d "$WORK" ]; }; then rm -f "$WORK"; fi
  mkdir -p -m 700 "$WORK" 2>/dev/null || true
}

put_data() {   # put_data тимчасовий_файл ім'я_в_data — безпечно покласти файл у data/ для програми
  [ -d data ] && [ ! -L data ] || { rm -f "$1"; return 0; }
  chmod 644 "$1"; chown -h 1000:1000 "$1" 2>/dev/null || true
  mv -fT "$1" "data/$2" 2>/dev/null || rm -f "$1"
}

rp() { case "$REMOTE" in *:) echo "$REMOTE$1" ;; *) echo "$REMOTE/$1" ;; esac; }

write_status() {   # write_status true|false "повідомлення" [true — виконується] — стан бачить адміністратор у програмі
  [ -d data ] || return 0
  local msg=${2//\"/\'}
  work_dir
  printf '{"time": "%s", "ok": %s, "message": "%s", "running": %s}\n' "$(date '+%F %T')" "$1" "$msg" "${3:-false}" > "$WORK/status.json"
  put_data "$WORK/status.json" cloud_backup.json
}
fail() { echo "ПОМИЛКА: $1" >&2; write_status false "$1"; exit 1; }

check_rclone() {
  command -v rclone >/dev/null 2>&1 || fail "rclone не встановлено: apt install rclone (README, розділ «Копія в Google Диск»)"
  rclone listremotes 2>/dev/null | grep -qx "${REMOTE%%:*}:" \
    || fail "у rclone немає сховища «${REMOTE%%:*}» — налаштуйте його (README, розділ «Копія в Google Диск»)"
}

app_running() { docker compose ps --status running -q nakazy 2>/dev/null | grep -q .; }

backup() {
  check_rclone
  exec 9>/tmp/nakazy-backup.lock
  flock -n 9 || { echo "Копія вже виконується"; exit 0; }
  echo "$(date '+%F %T') Копія в $REMOTE"
  write_status true "виконується" true
  work_dir
  [ -L data/uploads ] && fail "data/uploads — символьне посилання; копію скасовано"
  mkdir -p data/uploads
  local tmp="$WORK/orders.db"
  rm -f "$tmp"
  # узгоджена копія бази: якщо програма працює — SQLite backup усередині контейнера, і знімок іде потоком
  # прямо в закриту папку root (не через data/); інакше — копія файлу, якщо це справжній файл, а не посилання
  if app_running; then
    docker compose exec -T -u app nakazy python -c "import os, sqlite3, sys, tempfile; f, t = tempfile.mkstemp(suffix='.db'); os.close(f); s = sqlite3.connect('/data/orders.db'); d = sqlite3.connect(t); s.backup(d); d.close(); s.close(); sys.stdout.buffer.write(open(t, 'rb').read()); os.remove(t)" > "$tmp" \
      || fail "не вдалося зробити копію бази"
  else
    { [ -f data/orders.db ] && [ ! -L data/orders.db ] && cp data/orders.db "$tmp"; } 2>/dev/null || fail "немає data/orders.db"
  fi
  [ -s "$tmp" ] || fail "копія бази порожня"
  echo "1/4 База"
  rclone copyto "$tmp" "$(rp "db/orders_$TODAY.db")" || { rm -f "$tmp"; fail "не вдалося вивантажити базу"; }
  rm -f "$tmp"
  echo "2/4 Скани (перший раз довго, далі — лише нові)"
  rclone sync data/uploads "$(rp uploads)" --backup-dir "$(rp "deleted/$TODAY")" --transfers 4 \
    || fail "не вдалося вивантажити скани"
  echo "3/4 Налаштування й сертифікати"
  [ -f .env ] && { rclone copyto .env "$(rp config/env)" || fail "не вдалося вивантажити .env"; }
  [ -d caddy/data ] && { rclone sync caddy/data "$(rp config/caddy)" || fail "не вдалося вивантажити caddy/data"; }
  echo "4/4 Прибирання копій, старших за $KEEP днів"
  local cut f d
  cut=$(date -d "-$KEEP days" +%F)
  for f in $(rclone lsf "$(rp db)" 2>/dev/null); do
    d=${f#orders_}; d=${d%.db}
    if [[ "$d" < "$cut" ]]; then rclone deletefile "$(rp "db/$f")"; fi
  done
  for f in $(rclone lsf --dirs-only "$(rp deleted)" 2>/dev/null); do
    d=${f%/}
    if [[ "$d" < "$cut" ]]; then rclone purge "$(rp "deleted/$d")"; fi
  done
  local n
  n=$(rclone lsf "$(rp db)" 2>/dev/null | wc -l)
  write_status true "База й скани скопійовано; копій бази в хмарі: $n"
  echo "Готово. Копій бази в хмарі: $n"
}

run_logged() {   # копія з журналом останнього запуску (data/cloud_backup.log — його видно в програмі)
  mkdir -p data
  work_dir
  backup 2>&1 | tee "$WORK/backup.log"
  put_data "$WORK/backup.log" cloud_backup.log
}

auto() {   # таймер запускає кожні 5 хв: копія на запит із програми або раз на день за розкладом
  command -v rclone >/dev/null 2>&1 || return 0                                  # копію не налаштовано
  rclone listremotes 2>/dev/null | grep -qx "${REMOTE%%:*}:" || return 0
  local run=0 at="" enabled=true now last
  if [ -f data/backup_request ]; then rm -f data/backup_request; run=1; fi       # «Зробити копію зараз»
  if [ -f data/backup_schedule.json ]; then                                      # пише програма
    at=$(grep -o '"time": *"[0-2][0-9]:[0-5][0-9]"' data/backup_schedule.json | grep -o '[0-2][0-9]:[0-5][0-9]')
    grep -q '"enabled": *false' data/backup_schedule.json && enabled=false
  fi
  [ -n "$at" ] || at="02:30"
  now=$(date +%H:%M)
  last=$(cat data/.backup_last_auto 2>/dev/null || true)
  if [ "$enabled" = true ] && [[ ! "$now" < "$at" ]] && [ "$last" != "$TODAY" ]; then
    work_dir
    echo "$TODAY" > "$WORK/last_auto"
    put_data "$WORK/last_auto" .backup_last_auto
    run=1
  fi
  if [ "$run" = 1 ]; then run_logged; fi
  return 0
}

list() {
  check_rclone
  echo "Копії бази (сховище $REMOTE):"
  rclone lsf "$(rp db)" 2>/dev/null | sed -n 's/^orders_\(.*\)\.db$/  \1/p' | sort
}

restore() {
  check_rclone
  exec 9>/tmp/nakazy-backup.lock   # поки відновлюємо, автоматична копія не запуститься
  flock -n 9 || { echo "Зараз виконується копія в хмару — спробуйте за кілька хвилин."; exit 1; }
  local want="${1:-}" stamp old
  if [ -z "$want" ]; then
    want=$(rclone lsf "$(rp db)" 2>/dev/null | sed -n 's/^orders_\(.*\)\.db$/\1/p' | sort | tail -1)
  fi
  [ -n "$want" ] || { echo "У хмарі немає копій бази."; exit 1; }
  rclone lsf "$(rp "db/orders_$want.db")" 2>/dev/null | grep -q . || { echo "Немає копії за $want."; list; exit 1; }
  echo "Буде відновлено базу за $want і скани з хмари (у їхньому останньому стані)."
  echo "Поточна папка data (якщо є) збережеться як data_before_restore_ДАТА_ЧАС."
  read -r -p "Продовжити? Введіть «так»: " a
  [ "$a" = "так" ] || { echo "Скасовано."; exit 1; }
  stamp=$(date +%Y-%m-%d_%H%M%S); old=""
  docker compose stop >/dev/null 2>&1 || true
  if [ -d data ]; then old="data_before_restore_$stamp"; mv data "$old"; fi
  mkdir -p data/uploads data/backups
  undo() { echo "ПОМИЛКА: $1. Повертаю попередні дані."; rm -rf data; [ -n "$old" ] && mv "$old" data; docker compose up -d; exit 1; }
  echo "1/3 База"
  rclone copyto "$(rp "db/orders_$want.db")" data/orders.db || undo "не вдалося завантажити базу"
  echo "2/3 Скани"
  rclone copy "$(rp uploads)" data/uploads --transfers 4 || undo "не вдалося завантажити скани"
  [ -n "$old" ] && [ -f "$old/secret.key" ] && cp -a "$old/secret.key" data/   # щоб користувачам не входити заново
  echo "3/3 Налаштування"
  # .env з копії — якщо тут його немає або це щойно створений install.sh (лише пароль початкового адміністратора)
  if [ ! -f .env ] || ! grep -v '^[[:space:]]*#' .env | grep -v '^[[:space:]]*$' | grep -qv '^INITIAL_ADMIN_PASSWORD='; then
    [ -f .env ] && cp -a .env ".env.before_restore_$stamp"
    rclone copyto "$(rp config/env)" .env 2>/dev/null && chmod 600 .env && echo "  .env (порт, HTTPS) відновлено з хмари"
  else
    rclone copyto "$(rp config/env)" ".env.from_backup" 2>/dev/null && chmod 600 .env.from_backup \
      && echo "  тут уже є свій .env — його не змінено; .env з копії збережено як .env.from_backup"
  fi
  if [ ! -d caddy/data ] && rclone lsf "$(rp config/caddy)" 2>/dev/null | grep -q .; then
    mkdir -p caddy/data && rclone copy "$(rp config/caddy)" caddy/data && echo "  сертифікати HTTPS відновлено з хмари"
  fi
  # запускаємо з налаштуваннями відновленого .env (COMPOSE_FILE міг змінитися)
  unset COMPOSE_FILE SITE_ADDRESS HTTPS_PORT CADDY_TLS HTTP_PORT
  docker compose up -d --remove-orphans
  echo "Готово: дані за $want відновлено.${old:+ Попередні дані — у папці $old (видаліть, коли переконаєтесь, що все гаразд).}"
}

timer() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустіть від root"; exit 1; }
  check_rclone
  local dir; dir=$(pwd)
  cat > /etc/systemd/system/nakazy-backup.service <<EOF
[Unit]
Description=Резервна копія «Реєстру наказів» у хмару
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$dir
ExecStart=$dir/backup_gdrive.sh --auto
EOF
  cat > /etc/systemd/system/nakazy-backup.timer <<EOF
[Unit]
Description=Копія «Реєстру наказів» у хмару: перевірка розкладу кожні 5 хв

[Timer]
OnBootSec=2min
OnCalendar=*:0/5

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now nakazy-backup.timer
  echo "Готово: автоматичну копію ввімкнено. Час (за замовчуванням 02:30) і «Зробити копію зараз» —"
  echo "у програмі: Адміністрування → Налаштування."
  echo "Журнал копій:      journalctl -u nakazy-backup -n 50"
}

drive_ok() { timeout 90 rclone lsd "$1" >/dev/null 2>&1; }   # Диск справді відповідає (є дійсний ключ доступу)

write_keys() {   # файл ключів шифрування. write_keys [пароль1 пароль2] — без аргументів відтворює з налаштувань rclone
  local keys=/root/nakazy-backup-KEYS.txt crypt="${REMOTE%%:*}" cfg p1="${1:-}" p2="${2:-}" note=""
  cfg=$(rclone config file 2>/dev/null | tail -1)
  if [ -z "$p1" ]; then
    # значення з rclone.conf (там вони закодовані) — розкодовуємо через rclone reveal
    obs() { awk -v s="[$crypt]" -v k="$1" '$0==s {f=1; next} /^\[/ {f=0} f && $1==k && $2=="=" {sub(/^[^=]*= */, ""); print; exit}' "$cfg"; }
    p1=$(rclone reveal "$(obs password)" 2>/dev/null || true)
    p2=$(rclone reveal "$(obs password2)" 2>/dev/null || true)
    [ -n "$p1" ] || note="(розкодувати не вдалося — для відновлення достатньо налаштувань нижче: там ключі в закодованому вигляді)"
  fi
  {
    echo "Ключі шифрування копій «Реєстру наказів» ($(date +%F))"
    echo "Без них відновити копію з Google Диска НЕМОЖЛИВО."
    echo
    echo "password  = ${p1:-—}"
    echo "password2 = ${p2:-—}"
    [ -n "$note" ] && echo "$note"
    echo
    echo "Повні налаштування rclone (на новому сервері покласти в /root/.config/rclone/rclone.conf):"
    echo "----------------------------------------"
    cat "$cfg"
  } > "$keys"
  chmod 600 "$keys"
  KEY1=${p1:-"(див. файл $keys — налаштування rclone)"}; KEY2=${p2:-"(там само)"}
}

setup() {
  [ "$(id -u)" -eq 0 ] || { echo "Запустіть від root"; exit 1; }
  local crypt="${REMOTE%%:*}" g ip p1 p2 keys a
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo "=== Налаштування копії в Google Диск (один раз) ==="
  echo
  if ! command -v rclone >/dev/null 2>&1; then
    echo "1/4 Встановлюю rclone..."
    apt-get update -qq && apt-get install -y -qq rclone || { echo "Не вдалося встановити rclone (потрібен інтернет)."; exit 1; }
  else
    echo "1/4 rclone вже встановлено"
  fi

  # Google Диск: наявне підключення перевіряємо; непрацююче (перервана спроба) — видаляємо й підключаємо заново
  local gname="google"
  g=$(rclone listremotes --long 2>/dev/null | awk '$2=="drive" {print $1; exit}')
  if [ -n "$g" ]; then
    gname="${g%:}"
    echo "2/4 Перевіряю підключення до Google Диска («$gname»)..."
    if drive_ok "$g"; then
      echo "    працює"
    else
      echo "    Підключення «$gname» не працює (мабуть, попередня спроба перервалася) — видаляю й підключаю заново."
      rclone config delete "$gname" >/dev/null 2>&1
      g=""
    fi
  fi
  if [ -z "$g" ]; then
    pkill -f "rclone config" >/dev/null 2>&1 && sleep 1   # звільнити порт 53682 від завислої попередньої спроби
    cat <<EOF
2/4 Підключення Google Диска. Потрібен браузер на вашому комп'ютері (лише зараз, один раз):

  а) На своєму комп'ютері відкрийте командний рядок (Win+R → cmd) і виконайте
     (замість admin — логін, яким ви заходите на сервер):
         ssh -L 53682:localhost:53682 admin@${ip:-IP-сервера}
     увійдіть паролем і НЕ закривайте це вікно.
  б) Нижче з'явиться посилання http://127.0.0.1:53682/auth?state=...
     ОДРАЗУ відкрийте його в браузері на своєму комп'ютері, увійдіть у Google-акаунт
     для копій і натисніть «Дозволити». Дочекайтеся в браузері сторінки «Success».

EOF
    read -r -p "Вікно з ssh відкрите й ви в ньому ввійшли? Натисніть Enter..." a
    rclone config create "$gname" drive scope=drive.file
    g=$(rclone listremotes --long 2>/dev/null | awk -v n="$gname:" '$1==n && $2=="drive" {print $1}')
    echo "    Перевіряю доступ до Диска..."
    if [ -z "$g" ] || ! drive_ok "$g"; then
      rclone config delete "$gname" >/dev/null 2>&1
      cat <<EOF

Google Диск НЕ підключився — недороблене підключення видалено, нічого лишнього не залишилось.
Найчастіші причини:
  • вікно з «ssh -L 53682:...» не було відкрите або закрилося (браузер писав «не вдається під'єднатися»);
  • посилання відкрили надто пізно або не натиснули «Дозволити»;
  • браузер відкрили на сервері, а не на своєму комп'ютері.
Просто запустіть ще раз:  ./backup_gdrive.sh --setup
EOF
      exit 1
    fi
    echo "    Google Диск підключено й перевірено."
  fi

  local show_keys=0
  if rclone listremotes 2>/dev/null | grep -qx "$crypt:"; then
    echo "3/4 Шифрування вже налаштовано ($crypt)"
    if [ ! -f /root/nakazy-backup-KEYS.txt ]; then
      echo "    файлу ключів немає — відтворюю його з налаштувань"
      write_keys; show_keys=1
    fi
  else
    echo "3/4 Налаштовую шифрування..."
    p1=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
    p2=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)
    rclone config create "$crypt" crypt remote="${g}nakazy-backup" filename_encryption=standard \
        directory_name_encryption=true password="$p1" password2="$p2" --obscure >/dev/null \
      || { echo "Не вдалося налаштувати шифрування."; exit 1; }
    write_keys "$p1" "$p2"; show_keys=1
  fi
  keys=/root/nakazy-backup-KEYS.txt
  if [ "$show_keys" = 1 ]; then
    p1=$KEY1; p2=$KEY2
    cat <<EOF

======================================================================
  ЗБЕРЕЖІТЬ КЛЮЧІ ШИФРУВАННЯ. Без них копію відновити неможливо.

      password  = $p1
      password2 = $p2

  Вони ж (разом із налаштуваннями) у файлі:  $keys
  Збережіть копію цього файлу НЕ на цьому сервері: флешка в сейф,
  менеджер паролів керівника тощо. Забрати файл на свій комп'ютер
  через WinSCP: спершу скопіюйте його у свою домашню папку
      cp $keys /home/admin/ && chown admin /home/admin/nakazy-backup-KEYS.txt
  (замість admin — ваш логін), заберіть і ОДРАЗУ видаліть ту копію:  rm /home/admin/nakazy-backup-KEYS.txt
  У файлі є й ключ доступу до вашого Google Диска — бережіть його як пароль.
======================================================================

EOF
    read -r -p "Записали ключі? Введіть «так»: " a
    while [ "$a" != "так" ]; do read -r -p "Збережіть ключі й введіть «так»: " a; done
  fi

  echo "4/4 Перша копія (перший раз вивантажуються всі скани — може тривати довго)..."
  run_logged
  timer
  echo
  echo "Усе налаштовано. Стан копії видно в програмі: Адміністрування → Налаштування."
}

case "${1:-}" in
  "") run_logged ;;
  --auto) auto ;;
  --setup) setup ;;
  --list) list ;;
  --restore) restore "${2:-}" ;;
  --timer) timer ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
