FROM alpine:3.22 AS certificates
RUN apk add --no-cache "ca-certificates>=20261020-r0"

FROM n8nio/runners:2.31.6@sha256:fd1c233abcbcc45a5a376132b2d48457e9eaab3c48d642eb276a314d2e4e67ed

USER root
# Replace hashed roots too, so OpenSSL cannot recover a removed CA from its CA path.
RUN rm -rf /etc/ssl/certs
COPY --from=certificates /etc/ssl/certs /etc/ssl/certs
COPY --from=certificates /etc/ssl/cert.pem /etc/ssl/cert.pem
COPY --from=ghcr.io/astral-sh/uv:0.13.4 /uv /uvx /usr/local/bin/

RUN python -m pip install --no-cache-dir --no-deps "pip @ https://files.pythonhosted.org/packages/3f/06/3e4420302363fbb71be3c7f35ce042f54bfca330e3e66b3a2e3c4cca579f/pip-26.2.2-py3-none-any.whl#sha256=fd7f4dfa8190e014013b9f08f3e973f4e4c26ffd179a204895533a7254813a70" \
    && python -m pip download --no-cache-dir --no-deps --dest /tmp/ca-bootstrap "certifi @ https://files.pythonhosted.org/packages/c4/51/29046e48f693c54e5b7412216d447a1d8362c9653148d98c02cdf65fa733/certifi-2026.10.19-py3-none-any.whl#sha256=42d35340cc5b9ba78e818ddbff0c5b1c2b779de448a340fd1b989f5fa8670e1b" \
    && uv pip install --python /opt/runners/task-runner-python/.venv/bin/python --no-index --no-deps /tmp/ca-bootstrap/*.whl \
    && uv pip check --python /opt/runners/task-runner-python/.venv/bin/python \
    && rm -rf /tmp/ca-bootstrap

USER runner
