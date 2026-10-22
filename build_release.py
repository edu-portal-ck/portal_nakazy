"""Збирає release/nakazy.zip з src/nakazy так, як очікує сервер:
папка nakazy/ у корені архіву, LF у текстових файлах, *.sh з правом виконання (unix-атрибути).
На сервері:  cd /opt && unzip -o nakazy.zip && cd nakazy && ./update.sh
"""
import os
import sys
import time
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "src", "nakazy")
OUT = os.path.join(ROOT, "release", "nakazy.zip")
# tools/ — разові утиліти для нашого сервера (перенесення зі старої СЕД, об'єднання дублікатів ПІП): у збірку не йдуть
SKIP_DIRS = {"data", "backups", "caddy", "tools", "__pycache__", ".git"}
SKIP_FILES = {".env"}
TEXT_EXT = {".py", ".sh", ".html", ".json", ".md", ".txt", ".yml", ".yaml", ".example", ""}


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for dirpath, dirnames, filenames in os.walk(SRC):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            rel_dir = os.path.relpath(dirpath, os.path.dirname(SRC)).replace("\\", "/")
            di = zipfile.ZipInfo(rel_dir + "/", time.localtime()[:6])
            di.create_system = 3
            di.external_attr = (0o40755 << 16) | 0x10
            z.writestr(di, b"")
            for name in sorted(filenames):
                if name in SKIP_FILES or name.endswith((".zip", ".pyc")):
                    continue
                path = os.path.join(dirpath, name)
                with open(path, "rb") as f:
                    data = f.read()
                if os.path.splitext(name)[1].lower() in TEXT_EXT or name.startswith((".", "Dockerfile")):
                    data = data.replace(b"\r\n", b"\n")
                zi = zipfile.ZipInfo(f"{rel_dir}/{name}", time.localtime(os.path.getmtime(path))[:6])
                zi.create_system = 3
                zi.external_attr = ((0o100755 if name.endswith(".sh") else 0o100644) << 16)
                zi.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(zi, data)
    os.replace(tmp, OUT)
    print("OK:", OUT)


if __name__ == "__main__":
    sys.exit(main())
