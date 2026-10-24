FROM python:3.12-slim
WORKDIR /app
# LibreOffice — для перегляду Word і Excel (.doc/.docx/.odt/.rtf/.xls/.xlsx/.ods) у вигляді PDF; шрифти — щоб кирилиця й розмітка Word збігалися з оригіналом
# користувач app (uid 1000): програма працює не від root
RUN apt-get update && apt-get install -y --no-install-recommends \
        libreoffice-writer libreoffice-calc fonts-liberation fonts-dejavu-core fonts-crosextra-carlito fonts-crosextra-caladea \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 1000 --user-group --create-home --home-dir /home/app app
# презентації (.ppt/.pptx/.odp) — окремим кроком, щоб на наявних серверах не перезавантажувати весь LibreOffice
RUN apt-get update && apt-get install -y --no-install-recommends libreoffice-impress \
    && rm -rf /var/lib/apt/lists/*
# архіви: libarchive читає RAR (ZIP, 7Z і TAR — бібліотеками Python)
RUN apt-get update && (apt-get install -y --no-install-recommends libarchive13t64 \
        || apt-get install -y --no-install-recommends libarchive13) \
    && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py index.html changelog.json ./
COPY help ./help
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh
ENV DATA_DIR=/data HOME=/home/app
VOLUME /data
EXPOSE 8000
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["gunicorn", "-b", "0.0.0.0:8000", "-w", "1", "--threads", "8", "--timeout", "180", "app:app"]
