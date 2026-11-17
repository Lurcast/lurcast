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
- Ogg Vorbis, Opus, FLAC, Speex, and Skeleton pass-through, including multiplexed logical streams
- Native FLAC and WebM (Opus or Vorbis) pass-through
- Mid-stream joins: MP3 and AAC bursts start at verified frame boundaries; Ogg bursts contain every logical stream's cached headers and resume at safe complete pages; FLAC and WebM listeners get the stream's headers, then audio from a FLAC frame or a WebM block (in a cluster header made for them)
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
- HLS output at `/<mount>.m3u8` for MP3, AAC (ADTS or LATM), Opus, and FLAC mounts, without transcoding, with optional low-latency HLS and multivariant playlists
- Recording mounts to files, with optional hourly (or any length) splits
- Webhooks for source, song, listener, recording, and reload events
- An access log in the combined format, and reloading `config.yml` without a restart
- Listener history charts (24 hours to 12 months) and a ban list for addresses, address ranges, and players
- HTTP and `ICY 200 OK` listener responses for Icecast/Shoutcast-compatible players
- Built-in plugins: automatic HTTPS with Let's Encrypt, transcoding to Opus, MP3, or (with the FDK AAC library installed) AAC, cover art (including SHOUTcast 2 album art), and listener logins from `htpasswd` files

Lurcast relays encoded audio as the source sends it; the optional transcode plugin can also publish a copy of a mount in another codec or at another bit rate.

## Install

Download the build for your machine (`amd64` or `arm64`) from the [latest release](https://github.com/lurcast/lurcast/releases/latest) and unpack it:

```sh
curl -fL https://github.com/lurcast/lurcast/releases/latest/download/lurcast-linux-amd64.tar.gz | sudo tar xz -C /opt
sudo ln -sf /opt/lurcast/lurcast /usr/local/bin/lurcast
lurcast --config config.yml
```

`/opt/lurcast` holds Lurcast with the shared libraries it uses and musl's dynamic loader, so it runs on any Linux distribution; the `lurcast` script starts it with them. To update, unpack a newer release over it.

Or run the Docker image:

```sh
docker run -p 8000:8000 -e LURCAST_SOURCE_PASSWORD=... -e LURCAST_ADMIN_PASSWORD=... -e LURCAST_RELAY_PASSWORD=... ghcr.io/lurcast/lurcast
```

## Build from source

Crystal 1.21.0 or newer is required. The repository's `.tool-versions` selects 1.21.0 for asdf users.

Install libogg, libopus, and LAME with `brew install libogg opus lame` on macOS or `sudo apt install libogg-dev libopus-dev libmp3lame-dev` on Debian/Ubuntu, plus a C compiler (the bundled decoders in `ext/` are compiled during the build). The specs also use the `ffmpeg` command to check audio.

```sh
shards build --release
./bin/lurcast --config config.yml
```

Change `admin_password`, `source_password`, and `relay_password` before exposing the server; Lurcast logs a warning at startup for any still set to the built-in default. Common scalar settings can also be overridden with `LURCAST_...` environment variables, including `LURCAST_PORT`, `LURCAST_SOURCE_PASSWORD` and `LURCAST_TLS_PORT`. The former `ICECAST_...` names remain aliases for deployment compatibility.

Lurcast uses Crystal 1.21's parallel execution context and scales up to the logical CPUs available to the process. Set `CRYSTAL_WORKERS` to a positive number to cap worker threads, or to `1` for single-threaded operation.

`burst_size` controls the audio sent to a newly connected listener, `queue_size` limits each slow listener's pending audio bytes, and `metadata_interval` controls ICY metadata insertion. The burst must not exceed the queue. Existing configurations may still use `buffer_size` as an alias for `burst_size`. `header_timeout` and `source_timeout` can split the connection-header and source-idle limits; both default to `timeout`.

`burst_seconds` and `queue_seconds` give the burst and queue as seconds of audio instead, so one setting suits every bitrate. A mount sizes them from the bitrate its source declares (`Ice-Bitrate` or `icy-br`), then every 10 seconds from the rate the source actually sends at, which also covers VBR, FLAC and Ogg streams that don't declare one; it changes a size only when it is more than 25% off. Listeners already connected keep their queue. A mount's own `burst_size` or `queue_size` comes before a global `burst_seconds` or `queue_seconds`.

`send_interval_ms` (default 250) lets a mount hold its source's audio for that long and send it to listeners in one piece. Encoders usually send one MP3 frame at a time, about 38 a second, and a write to every listener for each of them is most of the server's CPU. With 2,000 listeners on an Apple M1 Pro, the server used about 6.5 s of CPU per 15 s with 0 (each piece sent as it comes), 2.4 s with 100, 1.6 s with 250, and 0.9 s with 500. It adds at most that much delay, which players' own buffering of several seconds hides; set it lower, or 0, on a mount that needs the least delay. It can be set per mount.

`max_connections_per_ip` (default 5) limits sources, API and admin requests, and connections still sending headers from one address. Listeners stop counting against it once their stream starts, so many players behind one NAT address can tune in; set `max_listeners_per_ip` to cap them separately (unlimited by default). `rate_limit` new connections per `rate_limit_window` seconds still apply to every connection.

`max_bandwidth_kbps` caps the bandwidth listeners may take, counted as each listener's stream bitrate (HLS listeners are not counted): a new listener who would take the server over it is turned away. When a mount or the whole server is full (`max_listeners`, a mount's `max_listeners`, or `max_bandwidth_kbps`) and the mount has no `fallback_when_full`, Lurcast sends the listener a `302` redirect to the next of `redirect_servers` in turn, typically servers relaying this one:

```yaml
max_bandwidth_kbps: 900000   # about 900 Mbit/s
redirect_servers:
  - https://relay1.example.com
  - https://relay2.example.com
```

The redirect adds `lurcast_redirect=1` to the URL, and a server never redirects a request that has it, so a full relay can't send listeners back and forth. A server relaying this one logs in with `relay_username` and `relay_password` (a Lurcast relay does, with its `master_username` and `master_password`) and skips all these listener limits, including `max_listeners_per_ip`, so a full mount can't cut off its relays; it still counts as a listener.

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
    send_interval_ms: 250
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
plugins:
  access_log:
    path: /var/log/lurcast/access.log   # or "-" for standard output
```

Each request is written in the combined log format with the duration in seconds at the end, which log analysers and Icecast tools read. Listeners are logged when they disconnect, with the bytes they received. Passwords in query strings (`pass=`, `password=`) are masked. A reload reopens the file, so `logrotate` can move it and then reload.

### HLS

```yaml
plugins:
  hls:
    segment_seconds: 6
    window: 6              # segments in the playlist
    mounts: [/live]        # only these mounts; every mount HLS can serve when left out
    except: [/talk]        # never these
    low_latency: false     # partial segments and blocking playlist reloads
    part_seconds: 1.0      # with low_latency, 0.2 to 2
    variants:              # multivariant playlists: /radio.m3u8 offers both mounts
      /radio: [/live, /live-mobile]
```

Mounts get an HLS playlist at `/<mount>.m3u8` (for example `/live.m3u8`) for browsers and phones that prefer HLS. Lurcast cuts the audio into segments on frame boundaries without transcoding:

- MP3 and AAC become HLS packed audio, with ID3 timestamps and the song title. AAC in LATM (as DAB+ and DVB encoders send it) is rewritten as ADTS.
- Opus and FLAC, in Ogg or as native FLAC, become fragmented MP4 (CMAF) segments. Ogg Vorbis has no MP4 form, so Vorbis mounts are not offered over HLS.

With `low_latency: true`, AAC, Opus, and FLAC mounts use fragmented MP4 cut into parts of `part_seconds`, which players fetch as soon as each is ready, and players can wait for the next part instead of polling (blocking playlist reloads and preload hints). With 0.5-second parts, players stayed about 2 seconds behind live in testing, instead of three segments. MP3 keeps packed audio and normal latency.

A variant list publishes a multivariant playlist at `/<name>.m3u8` that offers each listed mount that is on the air, with its measured bandwidth and codec, so players pick the one that suits their connection. Pair it with the transcode plugin to offer, say, AAC at 128 kbps from your encoder and an Opus copy at 32 kbps.

HLS listeners are counted as addresses that fetched a segment recently, and count in the listener history. Playlist and segment requests don't count against `rate_limit`, because players make them all the time; `max_connections_per_ip` still applies, and a low-latency player holds two connections. Listener logins and the ban list apply to the playlist and every segment, but listener limits don't. The `url_auth` plugin checks listeners one connection at a time, so HLS stays off while it is on.

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
plugins:
  webhooks:
    timeout: 5                      # seconds (default 5)
    endpoints:
      - url: https://example.com/hooks/lurcast
        secret: change-me           # optional: signs each request
        events: [source.connected, source.disconnected, song.changed, recording.finished]
```

Events: `source.connected`, `source.disconnected`, `song.changed`, `listener.connected`, `listener.disconnected`, `recording.finished`, and `config.reloaded`. Without `events`, every event except the listener ones is sent. Each event is a JSON POST:

```json
{"event": "song.changed", "id": "5c1f…", "at": "2026-11-13T22:01:14Z", "server": "https://radio.example",
 "data": {"mount": "/live", "song": "Artist - Title", "listeners": 42}}
```

With a `secret`, `X-Lurcast-Signature: sha256=<hex>` is the HMAC-SHA256 of the raw body; compare it before trusting the request. `X-Lurcast-Event` and `X-Lurcast-Delivery` (the id) are also sent. Failed deliveries (no answer, or a status other than 2xx) are retried after 2 and 10 seconds. Each endpoint has its own queue, so a slow receiver never delays streaming.

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

## Plugins

Some features are plugins: they are built into the same binary but kept apart from the core server, in `src/plugins/`, and each one is turned on and set up in its own section under `plugins:` in `config.yml`. The dashboard shows the controls of the plugins that are on. Settings for a plugin that doesn't exist are an error, so typos are caught at startup.

The plugins are `cover_art`, `listener_logins`, `acme` (automatic HTTPS) and `transcode`, described below, and `hls`, `access_log`, `webhooks`, `url_auth` (external authentication) and `yp` (directory listings), described with those features elsewhere in this README. A configuration reload applies changed plugin settings and starts plugins that were turned on.

### Cover art

On by default. SHOUTcast 2 encoders (Ultravox 2.1) send the station logo and the cover of each song inside the stream; Lurcast keeps them and serves them to players:

- `/_lurcast/art/<mount>`: the song's cover, or the station logo when there is none (`?type=station` or `?type=playing` for one of them). Responses carry an `ETag`, so players can check for a new cover cheaply.
- `/streamart?sid=1` and `/playingart?sid=1`: the paths the SHOUTcast 2 server uses.
- The status JSON lists the path as `artwork` for each mount, and `/api/v1/stations` as `now_playing.artwork_url`.

Encoders that can't send artwork (Icecast sources) can have it uploaded from the dashboard's Settings tab, or by automation for every song:

```sh
curl --user admin:admin123 -H 'Content-Type: image/jpeg' --data-binary @cover.jpg 'http://localhost:8000/admin/artwork?mount=/live&type=playing'
curl --user admin:admin123 -H 'Content-Type: image/png' --data-binary @logo.png 'http://localhost:8000/admin/artwork?mount=/live&type=station'
curl --user admin:admin123 -X POST 'http://localhost:8000/admin/artwork/remove?mount=/live&type=playing'
```

Images are JPEG, PNG, GIF, WebP, or BMP, up to 1 MB. With `data_dir` set, station logos are kept in `cover_art/` there and survive restarts; song covers are kept in memory. Turn the plugin off with `plugins: {cover_art: {enabled: false}}`.

### Listener logins

Makes mounts private: listeners need a user name and password from an Apache `htpasswd` file. Players send them with HTTP Basic authentication, usually from a URL like `https://anna:secret@radio.example.com/private`.

```yaml
plugins:
  listener_logins:
    mounts:
      /private: /etc/lurcast/private.htpasswd
      "*": /etc/lurcast/listeners.htpasswd   # optional: every other mount
    realm: My Radio                           # optional: the name players show when they ask
```

Manage the logins in the dashboard (Settings tab of the mount), with the API, or by editing the file with `htpasswd`; Lurcast reads it again when it changes. Lurcast checks bcrypt, Apache MD5 (`$apr1$`), `{SHA}`, and Icecast's plain MD5 hashes, and saves new passwords with bcrypt.

```sh
curl --user admin:admin123 'http://localhost:8000/admin/api/listener-logins?mount=/private'
curl --user admin:admin123 -X POST 'http://localhost:8000/admin/listener-logins?mount=/private&user=anna&password=secret'
curl --user admin:admin123 -X POST 'http://localhost:8000/admin/listener-logins/remove?mount=/private&user=anna'
```

Protected mounts answer `401` without a valid login, on streams and HLS alike. Removing a user or changing a password doesn't disconnect players that are already listening.

### Automatic HTTPS

Gets a free certificate from Let's Encrypt for your domains, serves HTTPS with it, and renews it before it expires. No other software is needed. The domains must point at this server, and port 80 must be reachable from the internet so Let's Encrypt can check them.

```yaml
data_dir: /var/lib/lurcast          # required: the account key and certificate are kept in acme/ here
plugins:
  acme:
    domains: [radio.example.com, www.radio.example.com]
    email: ops@example.com          # optional: Let's Encrypt emails about problems with your certificate
    accept_terms: true              # you accept the certificate authority's terms of service
    https_port: 443                 # default 443
    http_port: 80                   # default 80; 0 when a proxy forwards /.well-known/acme-challenge/ to Lurcast's port
    redirect_http: false            # true sends every other request on http_port to HTTPS (301)
    renew_days: 30                  # renew this many days before expiry (default 30)
    # directory: https://acme-staging-v02.api.letsencrypt.org/directory   # Let's Encrypt staging, for trying it out
```

Lurcast checks the certificate at startup and every 12 hours. If it can't get one, it logs why and tries again after a minute, then waits twice as long each time, up to 6 hours; streams on the main port keep working meanwhile. HTTPS starts as soon as the first certificate arrives, and renewed certificates are used for new connections without a restart. Listeners use `https://radio.example.com/live`.

- Every domain is on one certificate (up to 100). Wildcards (`*.example.com`) aren't supported, because they need DNS validation.
- Challenges are also answered on Lurcast's main port, so you can set `http_port: 0` if a proxy already forwards port 80 to Lurcast.
- Use this plugin or your own certificate (`tls_port`, `tls_cert`, `tls_key`), not both.
- Ports 80 and 443 need root or `CAP_NET_BIND_SERVICE` (for example `setcap 'cap_net_bind_service=+ep' /usr/local/bin/lurcast`, or `AmbientCapabilities=CAP_NET_BIND_SERVICE` in a systemd unit).
- Certificates are kept per certificate authority, so moving from the staging directory to the real one gets a new certificate. `kill -HUP` makes Lurcast check the stored certificate again at once; changing the domains or ports needs a restart.

### Transcoding

Re-encodes a mount on another mount: for example a low-bitrate Opus copy of your stream for listeners on mobile data, or an MP3 copy of an Opus stream for older players. It reads MP3, Ogg Vorbis, and Ogg Opus sources, and AAC sources when the [FDK AAC library](#aac-with-the-fdk-library) is installed.

```yaml
plugins:
  transcode:
    streams:
      - source: /live          # mount to read
        mount: /live.opus      # mount to publish
        codec: opus            # opus (Ogg Opus), mp3, or aac; default opus
        bitrate: 64            # kbps; default 64 for Opus, 128 for MP3 and AAC-LC
        channels: 2            # 1 or 2 (default 2)
      - source: /live
        mount: /live.mp3
        codec: mp3
        bitrate: 128
      - source: /live
        mount: /live-mobile.opus
        bitrate: 24
        channels: 1
```

| Codec | Bit rates | Output |
|---|---|---|
| `opus` | 6 to 256 kbps | Ogg Opus, 48 kHz, 20 ms frames |
| `mp3` | 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 192, 224, 256, or 320 kbps | constant bit rate MP3; 44.1 kHz from 96 kbps, a lower rate below that |
| `aac` | 8 to 320 kbps, within what the profile allows | AAC in ADTS, 44.1 kHz; needs the FDK AAC library |

At low bit rates Opus sounds clearly better than MP3.

The target mount appears while the source mount has a source connected, and goes away about two seconds after it disconnects (its listeners move to its fallback, if one is set); a source that reconnects within that time keeps the same stream going. Song titles on the source are copied to the target, and the station name, genre, description, and URL are copied when the target starts. Each stream costs a few percent of one CPU core.

Each target must be unique, can't be its own source, and streams can't feed into each other in a loop. Changes to the list apply on a configuration reload (`kill -HUP`), restarting the streams that changed.

MP3 is encoded with [LAME](https://lame.sourceforge.io/), under the LGPL; see [LICENSING.md](LICENSING.md#third-party-code). Releases include it as a separate shared library, `lib/libmp3lame.so.0`, built by `ext/build-lame.sh`, which you can replace with your own build.

#### AAC with the FDK library

Lurcast doesn't include an AAC codec. If the [Fraunhofer FDK AAC](https://github.com/mstorsjo/fdk-aac) library (`libfdk-aac.so.2`) is installed, Lurcast loads it when it starts and can then transcode AAC sources (ADTS or LATM, including HE-AAC) and publish AAC:

```yaml
      - source: /live
        mount: /live.aac
        codec: aac
        profile: he            # lc (default), he (HE-AAC), or hev2 (HE-AAC v2, stereo only)
        bitrate: 48            # default 128 for lc, 48 for he, 32 for hev2
```

Without the library, a stream with `codec: aac` is refused when the configuration is loaded, and AAC sources are logged as not transcodable; everything else works as usual.

- **Docker image:** build your own from it: `FROM ghcr.io/lurcast/lurcast`, then `USER root`, `RUN apk add --no-cache fdk-aac`, and `USER lurcast`.
- **Release tarball:** Lurcast runs with musl, so it needs a musl build of the library: put `libfdk-aac.so.2` in `/opt/lurcast/lib/` (for example from Alpine's `fdk-aac` package), or on Alpine Linux install that package. A library built for glibc (Debian's or Ubuntu's `libfdk-aac2`) can't be loaded.
- **Built from source:** the system's `libfdk-aac` is used (Homebrew `fdk-aac`, Debian and Ubuntu `libfdk-aac2`).

Some distributions ship FDK with AAC-LC only (Alpine and Fedora do, because of patents). With such a build, `profile: he` and `hev2` are refused with a message saying so; for HE-AAC, install a full build, such as one compiled from the [upstream source](https://github.com/mstorsjo/fdk-aac).

FDK's license grants no patent rights and allows its use only where you hold the patent licenses it needs (from [Via LA](https://www.via-la.com/) or the patent holders); AAC-LC's US patents have expired, HE-AAC's are still in force in places. Whether you may use it is up to you. Lurcast doesn't distribute FDK; see [LICENSING.md](LICENSING.md#open-source-edition) for the permission to combine the two.

### Writing a plugin

A plugin is a subclass of `Lurcast::Plugin` in its own file under `src/plugins/`; it is found and built in at compile time. `register` names its section under `plugins:`, a `Settings` subclass lists the settings with their defaults, and methods marked with `@[Route]` answer requests:

```crystal
module Lurcast::Plugins
  class Greeter < Plugin
    register "greeter"   # add `enabled_by_default: true` to build it without a section

    class Settings < Plugin::Settings
      getter greeting : String = "Hello"

      def validate!(config : Config) : Nil
        invalid("greeting must not be empty") if greeting.empty?
      end
    end

    @[Route("GET", "/hello")]
    private def hello(context : Context) : Nil
      context.text("#{settings.greeting}, #{context.param("name")}")
    end

    @[Route("POST", "/admin/greeting", admin: true)]   # asks for an admin login first
    private def change(context : Context) : Nil
      mount = context.mount   # the ?mount= the login may manage, or a 404
      context.json({mount: mount, user: context.access.user})
    end
  end
end
```

Every section also takes `enabled: false`, and unknown settings are an error that names the plugin. `GET` routes answer `HEAD` too, `prefix: true` matches every path under the given one, `suffix: true` every path that ends with it, `listener: true` marks requests players make all the time (they don't count against `rate_limit`), and `context.halt(404, "message")` ends a route with a JSON error. `reload(settings)` runs after a configuration reload, with nil when the section was removed. Each plugin logs as `lurcast.plugins.<name>` and keeps its files in `data_dir/<name>/`.

The core server knows no plugin by name: plugins work only through the hooks in `src/extension.cr`, which they override. Among them:

- `source_connected`, `source_disconnected`, `song_changed`, `listener_connected`, `listener_finished` and others, to follow what happens;
- `listener_challenge` and `source_login`, to decide who may listen or send;
- `mount_fields(mount, view)`, to add fields to a mount in the status JSON, `/api/v1/stations` (the station or its `now_playing`) and the dashboard's data;
- `listener_count`, for listeners a plugin serves itself (they count in the listener history), and `checks_each_listener?`, which keeps such features off a mount whose listeners must each have a connection;
- `ultravox_metadata`, for the binary metadata SHOUTcast 2 sources send, such as artwork.

A plugin adds to the dashboard with a script next to its source, `dashboard "my_plugin/dashboard.js"`, which registers its parts: labels, figures and links for a mount, an image next to the song playing, and panels on the Settings tab. The top of `src/web/admin.js` lists them; `src/plugins/hls/dashboard.js` is a short example.

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

For external authentication, turn on the `url_auth` plugin. Lurcast sends form-encoded `stream_auth`, `listener_add`, `listener_remove`, `mount_add`, and `mount_remove` callbacks. Authorization callbacks are accepted only when the response is successful and contains the configured header with value `1`:

```yaml
plugins:
  url_auth:
    url: https://auth.example/icecast
    header: icecast-auth-user   # the default
    timeout: 5                  # seconds (default 5)
```

To publish source streams that send `Ice-Public: 1` or `icy-pub: 1`, list one or more YP directories with the `yp` plugin:

```yaml
hostname: radio.example
public_url: https://radio.example
admin_email: admin@example.com
plugins:
  yp:
    urls:
      - https://dir.xiph.org/cgi-bin/yp-cgi
    touch_interval: 60          # seconds between updates (default 60)
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

The `Dockerfile` builds the same folder as the release tarballs on Alpine (`deploy/bundle.sh`) and runs it as an unprivileged user. Mount a config at `/etc/lurcast/config.yml` or configure with environment variables:

```sh
docker build -t lurcast .
docker run -p 8000:8000 -e LURCAST_SOURCE_PASSWORD=... -e LURCAST_ADMIN_PASSWORD=... -e LURCAST_RELAY_PASSWORD=... lurcast
```

For systemd hosts, `deploy/lurcast.service` is a hardened unit that runs `/usr/local/bin/lurcast` (the link made when installing) as the `lurcast` user. Each listener holds one socket, so keep the open file limit (`LimitNOFILE`, or `ulimit -n`) above `max_listeners`.

## Load test

`bench/load_test.cr` connects one paced 128 kbps MP3 source and N listeners, then reports how many listeners kept up with the stream rate. Raise `max_listeners` and `rate_limit` on the server under test first.

```sh
crystal build --release bench/load_test.cr -o bin/load_test
bin/load_test --port 8000 --password SOURCE_PASSWORD --listeners 5000 --duration 30
```

On an Apple M1 Pro laptop, with the server and load generator on the same machine, a release build served 5,000 listeners (640 Mbit/s) at full rate with no drops, using about 1.1 CPU cores and 360 MB of memory. Memory is dominated by each listener's initial burst, so it scales with `burst_size`.

With both on one machine, the load generator competes with the server for the CPU and figures vary a lot from run to run. For numbers to compare, run the server on one Linux machine and the load generator on another, and measure the server where it runs:

```sh
# On the server machine: a release build, with limits raised for the test.
ulimit -n 65536
bin/lurcast -c bench.yml        # max_listeners, max_connections_per_ip and rate_limit above the test

# On the load machine: more local ports and files than listeners, then the test.
sudo sysctl -w net.ipv4.ip_local_port_range="1024 65000"
ulimit -n 65536
bin/load_test --host SERVER --port 8000 --password SOURCE_PASSWORD --listeners 10000 --duration 60 --ramp 20

# On the server machine again, once every listener has connected:
bench/server_stats.sh $(pgrep -x lurcast) 30 10000
```

Run each comparison at least three times. One load machine reaches about 60,000 listeners to one server port before it runs out of local ports; use more load machines beyond that. Wait a minute between runs from the same machine, so the last run's connections have left TIME_WAIT.

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
