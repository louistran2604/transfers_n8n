FROM python:3.13.14-slim@sha256:6771159cd4fa5d9bba1258caf0b82e6b73458c694d178ad97c5e925c2d0e1a91

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SOCCERDATA_DIR=/data/soccerdata \
    TLS_LIBRARY_PATH=/opt/sofascore/tls-client-xgo-1.13.1-linux-amd64.so

ADD --checksum=sha256:3f9bf4a741002b1d57043571d69e6ebe8f1df416aa1ca9ca9766dba36e4d4941 \
    https://github.com/bogdanfinn/tls-client/releases/download/v1.13.1/tls-client-xgo-1.13.1-linux-amd64.so \
    /opt/sofascore/tls-client-xgo-1.13.1-linux-amd64.so

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir --require-hashes -r requirements.txt \
    && echo "3f9bf4a741002b1d57043571d69e6ebe8f1df416aa1ca9ca9766dba36e4d4941  ${TLS_LIBRARY_PATH}" | sha256sum -c - \
    && chmod 0555 "${TLS_LIBRARY_PATH}" \
    && python -c "from tls_requests import TLSLibrary; assert TLSLibrary.load() is not None" \
    && groupadd --gid 10001 sofascore \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin sofascore \
    && mkdir -p /data/soccerdata \
    && chown -R sofascore:sofascore /data/soccerdata /app

COPY --chown=sofascore:sofascore __init__.py app.py adapter.py identity.py competition.py models.py ./
COPY --chown=sofascore:sofascore tests ./tests

USER 10001:10001

CMD ["python", "app.py"]
