FROM python:3.13.14-slim@sha256:6771159cd4fa5d9bba1258caf0b82e6b73458c694d178ad97c5e925c2d0e1a91

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    SOCCERDATA_DIR=/data/soccerdata \
    TLS_LIBRARY_PATH=/opt/sofascore/tls-client-xgo-1.13.1-linux-amd64.so

ADD --checksum=sha256:3f9bf4a741002b1d57043571d69e6ebe8f1df416aa1ca9ca9766dba36e4d4941 \
    https://github.com/bogdanfinn/tls-client/releases/download/v1.13.1/tls-client-xgo-1.13.1-linux-amd64.so \
    /opt/sofascore/tls-client-xgo-1.13.1-linux-amd64.so

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && python -m pip install --no-cache-dir --no-deps "pip @ https://files.pythonhosted.org/packages/3f/06/3e4420302363fbb71be3c7f35ce042f54bfca330e3e66b3a2e3c4cca579f/pip-26.2.2-py3-none-any.whl#sha256=fd7f4dfa8190e014013b9f08f3e973f4e4c26ffd179a204895533a7254813a70"

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
