# Self-hosted Anki sync server, version-pinned to the EXACT engine commit the
# iOS app is built from (rslib is unmodified upstream, so the commit fully
# defines the sync protocol). This guarantees client/server protocol parity —
# the reason the local same-version test passed where AnkiWeb's older server
# rejected the full upload ("missing original size").
FROM rust:1.92.0-alpine3.23 AS builder

RUN apk update && apk add --no-cache build-base protobuf && rm -rf /var/cache/apk/*

# Pinned to the app engine's commit (anki-desktop/main HEAD = 25.09.2-265-gb00308e55).
RUN cargo install --git https://github.com/ankitects/anki.git \
    --rev b00308e551576f5a71593a80f377bc1d28c6612e \
    --root /anki-server \
    --locked \
    anki-sync-server

FROM alpine:3.23

ENV PUID=1000
ENV PGID=1000

COPY --from=builder /anki-server/bin/anki-sync-server /usr/local/bin/anki-sync-server

RUN apk update && apk add --no-cache bash su-exec curl && rm -rf /var/cache/apk/*

EXPOSE 8080

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["anki-sync-server"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD anki-sync-server --healthcheck

VOLUME /anki_data
