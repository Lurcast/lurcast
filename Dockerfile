FROM crystallang/crystal:1.21.1-alpine AS build
RUN apk add --no-cache libogg-dev libogg-static
WORKDIR /src
COPY shard.yml shard.lock ./
COPY src ./src
RUN shards build lurcast --production --release --static --no-debug

FROM alpine:3.22
RUN apk add --no-cache ca-certificates \
    && addgroup -S lurcast && adduser -S -G lurcast -H lurcast \
    && mkdir -p /etc/lurcast /var/lib/lurcast && chown lurcast:lurcast /var/lib/lurcast
COPY --from=build /src/bin/lurcast /usr/local/bin/lurcast
COPY LICENSE LICENSING.md /usr/share/licenses/lurcast/
USER lurcast
EXPOSE 8000
# Mount a config at /etc/lurcast/config.yml, or configure with LURCAST_* environment variables.
# Bans and listener history; mount a volume here to keep them.
ENV LURCAST_DATA_DIR=/var/lib/lurcast
ENTRYPOINT ["/usr/local/bin/lurcast"]
CMD ["--config", "/etc/lurcast/config.yml"]
