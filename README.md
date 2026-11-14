# Lurcast

[![CI](https://github.com/lurcast/lurcast/actions/workflows/ci.yml/badge.svg)](https://github.com/lurcast/lurcast/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/license-AGPL--3.0-blue)](LICENSE)

[Website](https://lurcast.com) · [Documentation](https://lurcast.com/docs) · [Releases](https://github.com/lurcast/lurcast/releases)

Lurcast is an Icecast/Shoutcast-compatible streaming server written in Crystal. It accepts live sources, serves late-joining listeners, and provides relays, fallbacks, authentication hooks, directory publishing, ICY metadata, and JSON status APIs.

The name comes from the *lur*, a Bronze Age Nordic horn used to signal across valleys.

## Editions

- **Lurcast** (this README): the open-source streaming server, licensed under the [GNU AGPL-3.0](LICENSE).
- **[Lurcast Hosting edition](https://lurcast.com/#hosting)**: a separate, commercial add-on (not in this repository) for stream hosting providers. It runs every customer station in one process, with a provisioning API, customer logins to the dashboard, usage metering and transfer quotas, bitrate caps, Prometheus metrics, royalty reports, listener locations by country, and a WHMCS module. It needs a paid license key.

See [LICENSING.md](LICENSING.md) for details.

## Supported now

- Icecast source uploads using HTTP `PUT` and legacy `SOURCE`, including chunked transfer encoding
- A dedicated SHOUTcast source port supporting v1 and encrypted Ultravox 2.1 sources with SID-to-mount routing
- Plain HTTP and native TLS listeners
- Direct Icecast mount URLs plus SHOUTcast v1 `/;` and v2 `/stream/<sid>` listener aliases
- MP3 MPEG 1/2/2.5 Layer I/II/III, including free-format streams, plus AAC ADTS and LATM/LOAS frame synchronization, with malformed source bytes removed before fanout
- Ogg Vorbis, Opus, Theora, Speex, and Skeleton pass-through, including multiplexed logical streams
- Mid-stream joins: MP3 and AAC bursts start at verified frame boundaries; Ogg bursts contain every logical stream's cached headers and resume at safe complete pages
- Other container/codecs are relayed transparently, without format-specific mid-stream repair
- Basic authentication for source and admin requests, plus an external URL authentication lifecycle
- Reconnecting and on-demand HTTP(S) pull relays, Icecast master discovery, and source/file fallback chains
- YP directory add/touch/remove publishing for listed streams
- Multiple mounts, listener/source/IP limits, request rate limits, CORS, and a bounded connect burst
- Byte-bounded per-listener queues, so a slow player is disconnected without stalling the source
- `.m3u` playlists, a native `/api/v1/stations` JSON API, Icecast-compatible status JSON, and admin metadata/source-disconnect endpoints
- Icecast XML admin endpoints: `/admin/stats`, `/admin/listmounts`, `/admin/listclients`, `/admin/killclient`, and `/admin/moveclients`
- SHOUTcast DNAS endpoints: `/7.html`, `/stats`, `/statistics`, `/currentsong`, song history at `/played` and `/played.html`, and `admin.cgi` modes `updinfo`, `viewxml`, `viewjson`, `kicksrc`, and `kickdst`
- Per-mount source credentials, hidden mounts, and intro files
- A public status page at `/` (also `/status.xsl`) with a player and live now-playing, and a web admin dashboard at `/admin/`
- HLS output for MP3 and AAC mounts at `/<mount>.m3u8`, without transcoding
- Recording mounts to files, with optional hourly (or any length) splits
- Webhooks for source, song, listener, recording, and reload events
- An access log in the combined format, and reloading `config.yml` without a restart
- Listener history charts (24 hours to 12 months) and a ban list for addresses, address ranges, and players
- HTTP and `ICY 200 OK` listener responses for Icecast/Shoutcast-compatible players

Lurcast relays encoded audio; it does not transcode streams.

## Install

Download a static Linux binary (x86-64 or ARM64) from the [latest release](https://github.com/lurcast/lurcast/releases/latest):

```sh
curl -fLo lurcast https://github.com/lurcast/lurcast/releases/latest/download/lurcast-linux-amd64
chmod +x lurcast
./lurcast --config config.yml
```

Or run the Docker image:

```sh
docker run -p 8000:8000 -e LURCAST_SOURCE_PASSWORD=... -e LURCAST_ADMIN_PASSWORD=... -e LURCAST_RELAY_PASSWORD=... ghcr.io/lurcast/lurcast
```

## Build from source

Crystal 1.21.0 or newer is required. The repository's `.tool-versions` selects 1.21.0 for asdf users.

Install libogg with `brew install libogg` on macOS or `sudo apt install libogg-dev` on Debian/Ubuntu.

```sh
shards build --release
./bin/lurcast --config config.yml
```

Change `admin_password`, `source_password`, and `relay_password` before exposing the server; Lurcast logs a warning at startup for any still set to the built-in default. Common scalar settings can also be overridden with `LURCAST_...` environment variables, including `LURCAST_PORT`, `LURCAST_SOURCE_PASSWORD`, `LURCAST_TLS_PORT`, and `LURCAST_AUTH_URL`. The former `ICECAST_...` names remain aliases for deployment compatibility.

Lurcast uses Crystal 1.21's parallel execution context and scales up to the logical CPUs available to the process. Set `CRYSTAL_WORKERS` to a positive number to cap worker threads, or to `1` for single-threaded operation.

`burst_size` controls the audio sent to a newly connected listener, `queue_size` limits each slow listener's pending audio bytes, and `metadata_interval` controls ICY metadata insertion. The burst must not exceed the queue. Existing configurations may still use `buffer_size` as an alias for `burst_size`. `header_timeout` and `source_timeout` can split the connection-header and source-idle limits; both default to `timeout`.

`max_connections_per_ip` (default 5) limits sources, API and admin requests, and connections still sending headers from one address. Listeners stop counting against it once their stream starts, so many players behind one NAT address can tune in; set `max_listeners_per_ip` to cap them separately (unlimited by default). `rate_limit` new connections per `rate_limit_window` seconds still apply to every connection.

## Optional services

Enable native TLS with a PEM certificate chain and private key:

```yaml
tls_port: 8443
tls_cert: /etc/lurcast/fullchain.pem
tls_key: /etc/lurcast/privkey.pem
public_url: https://radio.example:8443
```

`public_url` is the address used in playlists, status output, and the dashboard's listen links. Without it, Lurcast uses `http://<hostname>:<port>`.

Enable SHOUTcast sources, fallbacks, or reconnecting pull relays:

```yaml
shoutcast_port: 8001
shoutcast_mount: /shoutcast
shoutcast_mounts:
  2: /second-stream
uvox_cipher_key: foobar

fallbacks:
  /live: /backup
  /backup: /offline.mp3
fallback_override: true
webroot: /var/lib/lurcast
fallback_file_bitrate: 128

mounts:
  /live:
    burst_size: 32768
    queue_size: 262144
    metadata_interval: 16000
    max_listeners: 500
    max_listener_duration: 21600
    fallback: /backup
    fallback_override: true
    fallback_when_full: true

relays:
  - url: https://upstream.example/live.ogg
    mount: /relay.ogg
    username: relay
    password: secret
    retry_delay: 5
    on_demand: true
```

When `/live` ends, its listeners move to `/backup`, then to the repeating `webroot/offline.mp3` file if `/backup` is unavailable. When a source returns, `fallback_override` moves its original listeners back. Mount entries override buffering, metadata cadence, listener limits, duration, and fallback behavior only where specified. A relay inherits its upstream `icy-metaint` unless its mount overrides `metadata_interval`. An authenticated admin can also update a fallback at runtime with `/admin/fallbacks?mount=/live&fallback=/backup`. An empty `fallback=` removes a runtime fallback, and the one from the configuration applies again.

Mounts can also require their own source login, stay off public status pages, or greet each new listener with an intro file:

```yaml
webroot: /var/lib/lurcast
song_history_size: 10

mounts:
  /dj:
    username: dj        # defaults to "source"
    password: turntable # replaces source_password for this mount
    intro: intro.mp3    # relative to webroot, sent once before the live burst
  /internal:
    hidden: true        # omitted from /, status JSON, /api/v1/stations, and /statistics
```

SHOUTcast v1 and Ultravox sources authenticate with the mount's password only. Hidden mounts still appear in authenticated admin responses. An intro file must use the mount's codec and must not exceed 16 MiB.

## Web pages

`/` (also served at Icecast's `/status.xsl`) lists the public stations with a player, the current song, listener counts, and recently played songs, and updates itself every 15 seconds. Hidden mounts are left out. `/played.html` shows a SHOUTcast stream's song history. Both pages work without JavaScript.

`/admin/` is the admin dashboard. Sign in with `admin_password`; the dashboard keeps the password for the browser tab (or on the device, if you choose) and sends it with each request, so the browser itself never stores admin credentials. It updates every 3 seconds and shows:

- listeners, stations on air, outgoing bandwidth, and uptime for the whole server
- listeners over time for the server and for each mount, over 24 hours, 7 days, 30 days, or 12 months
- every live, configured, and relay mount, with the current song, stream format, and listener statistics
- each mount's listeners (address, player, and time connected), which you can move to another mount, disconnect, or ban
- each mount's bans, to add and lift
- song history, encoder settings, and listen links to copy
- forms to change the song title, the station details, and the fallback, and to disconnect the source
- a warning while any password is still the default

The username is `admin`. Extensions can add logins limited to some mounts: the Hosting edition gives each customer one for their own station. Such a login sees only its mounts and cannot reload the configuration or see server-wide figures.

The data comes from `GET /admin/api/overview` (admin basic authentication), which scripts can use too. It lists every mount with its listener count (and listeners per country when locations are on); add `?clients=/live` to include the listener list for that mount, which the dashboard does only while its Listeners tab is open.

Admin requests that a browser marks as coming from a form, link, or image on another site are refused, so other pages cannot trigger admin actions with credentials a browser has stored. Scripts, encoders, and control panels are unaffected, and so are SHOUTcast requests that carry `pass=`.

Page assets are served from `/_lurcast/`, which therefore cannot be used as a mount name.

## Operations

### Reload the configuration

Send `SIGHUP` (`systemctl reload lurcast` with the bundled unit, or `kill -HUP <pid>`), press **Reload config** in the dashboard, or `POST /admin/reload` with admin credentials. Lurcast reads `config.yml` again and applies it without dropping listeners or sources: passwords, limits, mounts, fallbacks, relays, webhooks, the access log, the log level, and the TLS certificate (useful after renewing it). Fallbacks changed at runtime are replaced by the file's. If the file is invalid, the running configuration stays and the error is logged and returned. `host`, the ports, and the master relay settings need a restart; the reload reports them.

### Access log

```yaml
access_log: /var/log/lurcast/access.log   # or "-" for standard output
```

Each request is written in the combined log format with the duration in seconds at the end, which log analysers and Icecast tools read. Listeners are logged when they disconnect, with the bytes they received. Passwords in query strings (`pass=`, `password=`) are masked. A reload reopens the file, so `logrotate` can move it and then reload.

### HLS

```yaml
hls: true                  # or per mount: mounts: { /live: { hls: true } }
hls_segment_seconds: 6
hls_window: 6
```

MP3 and AAC (ADTS) mounts get an HLS playlist at `/<mount>.m3u8` (for example `/live.m3u8`) for browsers and phones that prefer HLS. Lurcast cuts the audio into segments on frame boundaries without transcoding, as HLS packed audio with ID3 timestamps; segments also carry the song title. Ogg and LATM streams are not offered over HLS. HLS listeners are counted as addresses that fetched a segment recently. HLS requests skip listener authentication and listener limits, so HLS stays off while `auth_url` is set.

### Recording

```yaml
recordings_dir: /var/lib/lurcast/recordings
record_split_minutes: 60   # new file every hour; 0 = one file per connection
mounts:
  /live:
    record: true           # record every time the source connects
```

Recordings are written to `<recordings_dir>/<mount>/<UTC start time>.<format>`, for example `live/2026-11-13_22-00-00.mp3`, exactly as the source sends the audio. Any mount can also be recorded on demand from the dashboard or with `POST /admin/record?mount=/live&action=start` (and `action=stop`); on-demand recordings stop when the source disconnects. MP3 and AAC files are split on frame boundaries; Ogg recordings are never split. The dashboard lists and downloads recordings; `GET /admin/api/recordings?mount=/live` lists them as JSON. Lurcast does not delete old recordings.

### Webhooks

```yaml
webhooks:
  - url: https://example.com/hooks/lurcast
    secret: change-me           # optional: signs each request
    events: [source.connected, source.disconnected, song.changed, recording.finished]
webhook_timeout: 5
```

Events: `source.connected`, `source.disconnected`, `song.changed`, `listener.connected`, `listener.disconnected`, `recording.finished`, and `config.reloaded`. Without `events`, every event except the listener ones is sent. Each event is a JSON POST:

```json
{"event": "song.changed", "id": "5c1f…", "at": "2026-11-13T22:01:14Z", "server": "https://radio.example",
 "data": {"mount": "/live", "song": "Artist - Title", "listeners": 42}}
```

With a `secret`, `X-Lurcast-Signature: sha256=<hex>` is the HMAC-SHA256 of the raw body; compare it before trusting the request. `X-Lurcast-Event` and `X-Lurcast-Delivery` (the id) are also sent. Failed deliveries (no answer, or a status other than 2xx) are retried after 2 and 10 seconds. Each webhook has its own queue, so a slow receiver never delays streaming.

### Listener history

Lurcast counts the listeners on every mount once a minute (HLS listeners included) and keeps the average and the peak per 5 minutes for 2 days, per hour for 35 days, and per day for 2 years. The dashboard charts them; `GET /admin/api/history?mount=/live&range=week` returns them as JSON (`range` is `day`, `week`, `month`, or `year`; leave out `mount` for the whole server). Each point is `[unix time, average, peak]`, with nulls for periods when the server was not running.

### Bans

Ban a listener from the dashboard's listener list or Bans tab, or with the API:

```sh
curl --user admin:admin123 -X POST 'http://localhost:8000/admin/bans?kind=address&value=203.0.113.0/24&minutes=1440&reason=ripping'
curl --user admin:admin123 -X POST 'http://localhost:8000/admin/bans?kind=user_agent&value=StreamRipper&mount=/live'
curl --user admin:admin123 'http://localhost:8000/admin/api/bans'
curl --user admin:admin123 -X POST 'http://localhost:8000/admin/bans/remove?id=<id>'
```

`kind=address` takes an IPv4 or IPv6 address or CIDR range (at most /8 for IPv4 and /16 for IPv6); `kind=user_agent` matches every player whose User-Agent contains the text, ignoring case. Without `mount` the ban applies to every mount; without `minutes` it lasts until lifted. Matching listeners are disconnected at once, and banned listeners get `403` on streams and HLS. Behind a reverse proxy, set `trusted_proxies` so bans use the listener's real address.

### Keeping state

```yaml
data_dir: /var/lib/lurcast
```

The Docker image sets it to `/var/lib/lurcast` (mount a volume there). With `data_dir` set, the ban list is kept in `bans.json` and the listener history in `listener-history.bin` there, so both survive restarts. `bans.json` is plain JSON; edit it and reload to change bans by hand. Without `data_dir`, both are kept in memory only.

### Behind a reverse proxy

Behind a reverse proxy such as nginx, list it in `trusted_proxies` so listener addresses, webhooks, and the access log use the client's address from `X-Forwarded-For` instead of the proxy's:

```yaml
trusted_proxies: [127.0.0.1, "::1", 10.0.0.0/8]
```

Connection and rate limits still apply to the address that connects.

## Admin and statistics endpoints

Icecast admin endpoints use `admin` basic authentication and respond with Icecast-style XML:

```sh
curl --user admin:admin123 http://localhost:8000/admin/stats
curl --user admin:admin123 'http://localhost:8000/admin/listclients?mount=/live'
curl --user admin:admin123 'http://localhost:8000/admin/killclient?mount=/live&id=12'
curl --user admin:admin123 'http://localhost:8000/admin/moveclients?mount=/live&destination=/backup'
```

`moveclients` moves every listener, or only the one given by `id`, to a different live mount with the same stream format. Moved listeners keep their original ICY metadata interval.

SHOUTcast-style statistics are public and addressed by stream ID (`sid`, default `1`), using `shoutcast_mount` and `shoutcast_mounts`:

```sh
curl http://localhost:8000/7.html
curl 'http://localhost:8000/stats?sid=1&json=1'
curl 'http://localhost:8000/statistics?json=1'
curl 'http://localhost:8000/played?sid=1&type=json'
curl 'http://localhost:8000/admin.cgi?sid=1&mode=viewxml&pass=admin123'
```

`/stats`, `/statistics`, and `/played` return XML unless `json=1` (or `type=json` for `/played`) is given. `kickdst` accepts a listener UID or IP address. `/nextsong` is not supported because sources do not announce upcoming tracks.

`admin.cgi` accepts the admin password as `pass=` in the query string and performs `kicksrc`, `kickdst`, and `updinfo` on GET, because SHOUTcast tools expect that. Query strings end up in proxy and access logs, so serve admin traffic over TLS and restrict `/admin.cgi` and `/admin/` to trusted addresses at your proxy or firewall.

Mirror mounts from another Icecast server (up to `max_sources`), optionally on demand:

```yaml
master_url: https://master.example:8443
master_username: relay
master_password: secret
master_update_interval: 120
relays_on_demand: true

# Credentials this server exposes to downstream master relays.
relay_username: relay
relay_password: change-me
```

For external authentication, set `auth_url`. Lurcast sends form-encoded `stream_auth`, `listener_add`, `listener_remove`, `mount_add`, and `mount_remove` callbacks. Authorization callbacks are accepted only when the response is successful and contains the configured header with value `1`:

```yaml
auth_url: https://auth.example/icecast
auth_header: icecast-auth-user
auth_timeout: 5
```

To publish source streams that send `Ice-Public: 1` or `icy-pub: 1`, configure one or more YP endpoints:

```yaml
hostname: radio.example
public_url: https://radio.example
admin_email: admin@example.com
yp_urls:
  - https://dir.xiph.org/cgi-bin/yp-cgi
```

## Send a stream

MP3, without transcoding:

```sh
ffmpeg -re -i song.mp3 -c copy -content_type audio/mpeg -f mp3 \
  icecast://source:source123@localhost:8000/radio.mp3
```

Ogg Opus:

```sh
ffmpeg -re -i song.mp3 -c:a libopus -content_type audio/ogg -f ogg \
  icecast://source:source123@localhost:8000/radio.ogg
```

Listen at `http://localhost:8000/radio.mp3` or `http://localhost:8000/radio.ogg`.

## Update metadata

```sh
curl --user source:source123 --get \
  --data-urlencode 'mount=/radio.mp3' \
  --data-urlencode 'mode=updinfo' \
  --data-urlencode 'song=Artist - Title' \
  http://localhost:8000/admin/metadata
```

Metadata is inserted only for MP3/AAC listeners that send `Icy-MetaData: 1`; it is never inserted into Ogg streams.

## Radio JSON API

`GET /api/v1/stations` returns Lurcast's stable JSON model for every active station. It includes current-song timestamps, station identity, listener totals, source protocol, listen URL, and observed MP3 technical details:

```sh
curl http://localhost:8000/api/v1/stations
```

Update an active station with admin or source basic authentication. Every field is optional, and an empty `current_song` clears it:

```sh
curl --user admin:admin123 --request PATCH \
  --header 'Content-Type: application/json' \
  --data '{"name":"Lurcast Radio","genre":"Jazz","current_song":"Artist - Title"}' \
  http://localhost:8000/api/v1/stations/radio.mp3
```

Icecast HTTP, SHOUTcast v1, SHOUTcast v2/Ultravox, relays, and fallback files are wire adapters around the same internal mount stream. The public API is JSON-only. Icecast `/admin/metadata`, SHOUTcast `/admin.cgi`, and Ultravox metadata updates remain supported for source compatibility. XML is parsed only when an Ultravox source sends the SHOUTcast v2 XML metadata payload required by that protocol.

## Deploy

The `Dockerfile` builds a static binary on Alpine and runs it as an unprivileged user. Mount a config at `/etc/lurcast/config.yml` or configure with environment variables:

```sh
docker build -t lurcast .
docker run -p 8000:8000 -e LURCAST_SOURCE_PASSWORD=... -e LURCAST_ADMIN_PASSWORD=... -e LURCAST_RELAY_PASSWORD=... lurcast
```

For systemd hosts, `deploy/lurcast.service` is a hardened unit that runs `/usr/local/bin/lurcast` as the `lurcast` user. Each listener holds one socket, so keep the open file limit (`LimitNOFILE`, or `ulimit -n`) above `max_listeners`.

## Load test

`bench/load_test.cr` connects one paced 128 kbps MP3 source and N listeners, then reports how many listeners kept up with the stream rate. Raise `max_listeners` and `rate_limit` on the server under test first.

```sh
crystal build --release bench/load_test.cr -o bin/load_test
bin/load_test --port 8000 --password SOURCE_PASSWORD --listeners 5000 --duration 30
```

On an Apple M1 Pro laptop, with the server and load generator on the same machine, a release build served 5,000 listeners (640 Mbit/s) at full rate with no drops, using about 1.1 CPU cores and 360 MB of memory. Memory is dominated by each listener's initial burst, so it scales with `burst_size`.

## Check

```sh
crystal tool format --check src spec bench
bin/ameba
crystal spec
```

CI runs these checks, a release build, and a Docker build with a smoke test on every push to `main` and every pull request. Pushing a `v*` tag builds the release binaries and the Docker image.

## License

Lurcast is free software under the [GNU Affero General Public License v3.0](LICENSE). The Hosting edition is a separate commercial product; see [LICENSING.md](LICENSING.md). Contributions are accepted under the terms in [CONTRIBUTING.md](CONTRIBUTING.md).

## Trademarks

SHOUTcast is a trademark of its owner, and Icecast is a trademark of the Xiph.Org Foundation. Lurcast is an independent implementation of the protocols those servers use, written from scratch. It is not affiliated with, endorsed by, or sponsored by either project, and it contains no code from them. The names appear here only to say which clients and tools Lurcast works with.

Lurcast and its logo are trademarks of the Lurcast authors; see [TRADEMARKS.md](TRADEMARKS.md) for how you may use them.
