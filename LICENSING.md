# Licensing

Lurcast comes in two editions. This repository holds the open-source edition only.

| Edition | Code | License |
|---|---|---|
| Lurcast (open source) | this repository | [GNU AGPL-3.0](LICENSE) |
| Lurcast Hosting edition | a separate, private repository | Commercial |

Copyright © 2024–2026 The Lurcast authors. All rights reserved except as granted by these licenses.

## Open source edition

The streaming server is free software under the GNU Affero General Public License, version 3 only.
You may run, study, change, and share it. If you run a modified version as a network service, the
AGPL requires you to offer that version's source code to its users.

## Hosting edition

The Hosting edition adds what stream hosting businesses need on top of the open-source server: the
station provisioning API, customer logins to the dashboard, usage metering and transfer quotas, bitrate caps, Prometheus metrics,
royalty reports, listener locations, and the WHMCS module. It is not open source. Using it requires
a paid license and a license key; its license is supplied with it. That license also covers the core
code built into the Hosting edition, so customers can modify the whole server without the AGPL's
obligations.

## Name and logo

The licenses above cover the code, not the Lurcast name or logo. See [TRADEMARKS.md](TRADEMARKS.md).

## Commercial licenses for the core

Companies that cannot meet the AGPL's terms (for example, to ship a modified server without
publishing their changes) can buy a commercial license for the core as well. Contact
info@lurcast.com.

## Contributions

Contributions are accepted under the [contributor agreement](CONTRIBUTING.md), which lets the
project keep offering both editions.

## Third-party code

The binary includes code from other projects, all under permissive licenses that allow both the
AGPL and the commercial licenses above:

| Component | Used for | License |
|---|---|---|
| [libopus](https://opus-codec.org/) | Opus encoding and decoding (transcode plugin) | BSD 3-clause |
| [libogg](https://xiph.org/ogg/) | Ogg page parsing | BSD 3-clause |
| [minimp3](https://github.com/lieff/minimp3) (vendored in `ext/`) | MP3 decoding (transcode plugin) | CC0 1.0 |
| [stb_vorbis](https://github.com/nothings/stb) (vendored in `ext/`) | Vorbis decoding (transcode plugin) | MIT or public domain |
| [SpeexDSP resampler](https://github.com/xiph/speexdsp) (vendored in `ext/`) | Resampling to 48 kHz (transcode plugin) | BSD 3-clause |

See [ext/README.md](ext/README.md) for the vendored versions. BSD-licensed components require their
copyright notices in binary distributions: [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt) has the license of
every part of the static binary (also OpenSSL, musl, the Crystal standard library, and others), and
ships with each release and in the Docker image at `/usr/share/licenses/lurcast/`.
