FROM crystallang/crystal:1.21.1-alpine AS build
RUN apk add --no-cache libogg-dev opus-dev xz
WORKDIR /src
# LAME, as a shared library built from its pinned release tarball.
COPY ext/build-lame.sh ./ext/
RUN sh ext/build-lame.sh
COPY shard.yml shard.lock ./
COPY ext ./ext
COPY src ./src
# libgcc is compiled in, so the only shared libraries in the bundle are ones meant to be shipped.
RUN shards build lurcast --production --release --no-debug --link-flags=-static-libgcc
# The same folder the release tarballs hold: the binary, its libraries, musl's loader, and a start script.
COPY deploy ./deploy
COPY LICENSE LICENSING.md THIRD_PARTY_NOTICES.txt ./
RUN sh deploy/bundle.sh bin/lurcast /opt/lurcast

FROM alpine:3.22
RUN apk add --no-cache ca-certificates \
    && addgroup -S lurcast && adduser -S -G lurcast -H lurcast \
    && mkdir -p /etc/lurcast /var/lib/lurcast && chown lurcast:lurcast /var/lib/lurcast
COPY --from=build /opt/lurcast /opt/lurcast
RUN ln -s /opt/lurcast/lurcast /usr/local/bin/lurcast \
    && mkdir -p /usr/share/licenses && ln -s /opt/lurcast /usr/share/licenses/lurcast
USER lurcast
EXPOSE 8000
# Mount a config at /etc/lurcast/config.yml, or configure with LURCAST_* environment variables.
# Bans and listener history; mount a volume here to keep them.
ENV LURCAST_DATA_DIR=/var/lib/lurcast
ENTRYPOINT ["/usr/local/bin/lurcast"]
CMD ["--config", "/etc/lurcast/config.yml"]
