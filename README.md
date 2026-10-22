# Реєстр наказів (portal_nakazy)

Вебпрограма для ведення реєстрів наказів установи: основні й кадрові накази, скани, пошук, журнал дій, кошик, HTTPS і резервні копії на Google Диск. Flask + SQLite, Docker.

## Завантажити

Готовий архів — у розділі **[Releases](https://github.com/edu-portal-ck/portal_nakazy/releases/latest)** (файл `nakazy.zip`).
Встановлення на сервер Debian/Ubuntu крок за кроком — [INSTALL.md](src/nakazy/INSTALL.md).

## Документація

- Повний опис можливостей і налаштувань: [src/nakazy/README.md](src/nakazy/README.md)
- Інструкція для адміністратора з встановлення: [src/nakazy/INSTALL.md](src/nakazy/INSTALL.md)

## Збірка з коду

```bash
python build_release.py
```

Готовий `release/nakazy.zip` копіюється на сервер у `/opt` і встановлюється командою `./install.sh` (перший раз) або `./update.sh` (оновлення).

## Ліцензія

GNU GPL v3 — див. [LICENSE](LICENSE).
