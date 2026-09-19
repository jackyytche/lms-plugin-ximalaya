# Ximalaya for Lyrion Music Server / Daphile (unofficial)

[![Latest release](https://img.shields.io/github/v/release/jackyytche/lms-plugin-ximalaya?sort=semver)](https://github.com/jackyytche/lms-plugin-ximalaya/releases/latest)
[![License](https://img.shields.io/github/license/jackyytche/lms-plugin-ximalaya)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-LMS%207.7%2B%20%7C%20Daphile-blue)](#requirements)
[![Tests](https://img.shields.io/badge/tests-295%20assertions%20in%205%20suites-brightgreen)](#tests)

An unofficial plugin that brings **Ximalaya** (ximalaya.com, a Chinese audiobook and
audio-streaming platform) to **Lyrion Music Server (LMS)** and **Daphile**: browse the
catalogue, search albums, queue and play episodes - including paid/VIP content - with
cover art, real bitrate/codec readouts, progress-bar seek and favourites integration.

> **Disclaimer**
> This is a personal, unofficial project. It is not affiliated with, endorsed by or
> supported by Ximalaya. It requires **your own** account cookie, is intended for
> **personal use only**, plays audio by streaming it directly from Ximalaya's CDN, and
> neither caches, re-hosts nor redistributes any audio. No account credentials are
> bundled with the plugin; the cookie you paste is stored in your own server's
> preferences only.

---

## Features

**Browsing**
- Plugin menu under **Apps**: My albums, Discover (rankings), Search albums, Paste a link/ID, Account status.
- Rankings: every channel with its charts (tab list cached for 1 hour), plus a
  "Browse all albums in this category..." entry at the end of each chart for the full
  category catalogue (multi-page assembly, exact totals).
- Album lists from several back ends, chosen automatically for exact episode counts and
  per-episode paid/VIP marks (mobile list - PC list - web list fallback).
- Native paging everywhere: the page width follows your UI setting, and a wider window
  is filled completely instead of leaving blank rows.

**Search**
- Album search straight from the plugin menu (mobile channel with a per-request
  signature), results carry cover art and the announcer, and page like any other list.

**Playback**
- Free and paid albums; paid episodes are resolved through the desktop-client channel
  (`device=win` plus request signing) with web/mobile fallbacks.
- Whole-album play/queue: `Play album` and the row `+`/`>` buttons queue the complete
  ordered episode list.
- **Progress-bar seek** at transcoder level: dragging the slider does not restart the
  episode (Daphile `Decode` receives the start offset).
- Queue rows show title, duration and cover immediately - not only the episode that is
  currently playing - and survive a server restart.

**Metadata and now playing**
- Real bitrate (computed from the stream size and duration rather than trusting the
  service metadata), real codec (FLAC / AAC / MP3, including Ximalaya's HD-AAC tier),
  duration and album art in the now-playing panel.
- Codec/bitrate appear within about two seconds on the Daphile skin (a polling client)
  without a page refresh, and are persisted per track so previously played episodes show
  them instantly.

**Favourites**
- Star any album from the album row's context menu. Starred albums stay browsable in
  LMS Favourites (their track list opens normally) and are mirrored into the plugin's
  editable **My albums** list. Single tracks can be starred without touching My albums.

**Errors you can act on**
- Messages instead of bare codes: expired cookie, missing VIP entitlement, server rate
  limiting (cool-down), empty result, category not served, signing failure.

---

## Requirements

| | |
|---|---|
| Server | Lyrion Music Server **7.7 or newer** (LMS 9.0.3 verified), or Daphile 25.05 |
| Perl | 5.14+ and the modules shipped with LMS; no extra CPAN packages |
| Account | A Ximalaya account; a web-login cookie (**required**, see below) |
| Players | Any Squeezebox-compatible player, including Daphile's own output devices |

Tested against Daphile 25.05 (LMS 9.0.3) with the **Daphile web skin**, the **Material
skin** and the device screen.

---

## Installation

1. In LMS/Daphile go to **Settings → Plugins** and add this as a **third-party repository**:

   ```
   https://github.com/jackyytche/lms-plugin-ximalaya/releases/latest/download/repo.xml
   ```

2. Install **Ximalaya** from the list and restart the server when prompted.
3. Open the plugin settings (Settings → Plugins → Ximalaya) and paste your cookie.

The plugin is then available in the main menu under **Apps → Ximalaya**.

*Updating later:* the same repository entry offers new versions; install and restart.

---

## Configuration

| Setting | What it does |
|---|---|
| **Cookie** (required) | Your ximalaya.com web-login cookie. Search also needs the `1&_token=` entry, which current web logins include. |
| **Quality** | Target audio tier: `64 kbps` (default), `32 kbps`, `128 kbps` or `Lossless / highest` (experimental). See the table below. |
| **PC channel** | `PC + web` (recommended) resolves paid albums through the desktop-client protocol; `web only` restricts the plugin to the web back end. |
| **Mobile channel** | `Auto` (recommended) uses the mobile album list for exact episode counts and per-episode VIP marks; `Off` disables it. |
| **My albums** | One album ID (or album link) per line - your editable album collection. Starring an album adds it here automatically. |

### Quality tiers

| Tier | Content served |
|---|---|
| `32 / 64 / 128 kbps` | The matching standard stream for free and paid episodes. |
| `Lossless / highest` | Original upload for free episodes; the highest client tier for paid ones. Falls back to a lower tier automatically when your account lacks the entitlement. |

### Getting your cookie

1. Log in to `https://www.ximalaya.com` in a desktop browser.
2. Open DevTools (**F12**) → **Network**, and click any request whose URL is on
   `www.ximalaya.com`.
3. Copy the whole **`Cookie`** request header value and paste it into the plugin setting.

The cookie is stored in your LMS preferences on your own server. Treat it like a
password: it grants access to your account, so do not post it in issues or logs.

---

## Known limitations

- **Rate limiting**: Ximalaya rate-limits its endpoints per channel. When a request is
  throttled the plugin enters a local ~60 second cool-down and tells you to retry;
  playback of already resolved episodes is unaffected.
- **Category breadth**: the category catalogue is served by Ximalaya's web back end; a
  slug the service does not serve (for example `qita`) reports "category not available"
  instead of an empty list.
- **Service drift**: Ximalaya changes its endpoints and signatures over time. If a whole
  area stops working, please open an issue with a log excerpt (see below).
- **Single account**: the plugin is designed for one personal account; it is not a
  multi-user or library-scanning service.

---

## Troubleshooting

**Grab a log first.** Enable `plugin.ximalaya` at **DEBUG** in
Settings → Advanced → Logging (it resets on restart), reproduce the problem, then fetch:

```
http://<your-server>:9000/log.txt?zip=1        # full server log as a zip
http://<your-server>:9000/server.log?lines=500 # tail, plain text
```

| Symptom | Meaning / fix |
|---|---|
| "Cookie expired / not logged in" | The cookie is stale or incomplete - log in again and paste a fresh one (search needs `1&_token=`). |
| "No permission (VIP)" | The episode needs a subscription or entitlement your account does not have; try a lower quality tier or another album. |
| "Rate limited, try again later" | Ximalaya throttled the request; wait about a minute. |
| "Category not available" | That catalogue slug is not served by Ximalaya. |
| Album tap returns to the main menu | Fixed in 0.1.55; please update the plugin and restart. |
| Codec/bitrate missing in the now-playing panel | Fixed in 0.1.49 (Daphile skin) and 0.1.48 (subscribed clients); update if you are on an older build. |
| Blank rows in the play queue | Fixed in 0.1.47; browsing the album once also repairs older rows. |

---

## Development

Pure Perl against the LMS plugin API, plus a small pure-Perl cryptography layer
(AES-128-ECB for the request-signing chain, with a FIPS-197 self-test executed at load
time). No CPAN dependencies beyond what LMS ships.

### Layout

```
Ximalaya/            plugin source (Plugin.pm, API.pm, ProtocolHandler.pm, ...)
t/                   offline stub test suites + fixtures
pack.py              builds a release zip (+ sha1) from install.xml's version
build.ps1            convenience build/verify script for Windows
repo.xml             third-party repository descriptor
```

### Tests

Five offline suites, **295 assertions** in total; they stub the LMS core and the network,
so they never touch Ximalaya's servers:

```sh
perl t/compile_check.pl        # 12  - the plugin loads and its handlers exist
perl t/ximacrypt_test.pl       # 17  - AES/signing primitives
perl t/zlib_store_test.pl      # 10  - compression/storage helpers
perl t/category_stub_test.pl   # 34  - catalogue parser, slug harvest, window assembly
perl t/pc_stub_test.pl         # 222 - album/track chains, queue metadata, row actions
```

Any Perl 5.14+ works; `perl t/pc_stub_test.pl` prints a pass/fail line per assertion.
Please run them (or add a case) before reporting a bug - they encode most of the
hard-won protocol behaviour.

### Key LMS hooks used

- `Slim::Music::Info::setRemoteMetadata` - now-playing metadata and cover art.
- Handler level `getMetadataFor` - takes over the queue's remote rows so bitrate/codec
  reach the panel.
- `Slim::Web::Pages->addPageFunction` - the OPML feed behind starred albums.
- `Slim::Player::Protocols::HTTP` + `canTranscodeSeek` - transcoder-level seek.
- `Slim::Control::XMLBrowser` row `itemActions` - album descent and context menus for
  both the Material and the Daphile skins.

### Releasing

```sh
python pack.py                      # writes dist/Ximalaya-<version>.zip + sha1
# update version + sha in repo.xml, commit, tag, then publish a GitHub release with
# Ximalaya.zip / repo.xml / ximalaya_logo.png as assets
```

---

## Changelog

Full notes for every build are on the [releases page](https://github.com/jackyytche/lms-plugin-ximalaya/releases).

| Version | Highlights |
|---|---|
| **0.1.55** | Album taps descend again in **both** skins (Material charts/search and the Daphile skin) - request parameters are now read where LMS puts them. |
| 0.1.54 | Material skin: tapping an album opens its track list again (explicit descend action on album rows). |
| 0.1.53 | Removed the row option that had been blocking the album descend (first step of 0.1.54). |
| 0.1.52 | Uniform cover art (CDN processing directives stripped) + album-cover fallback. |
| 0.1.51 | Album track lists fill the requested UI window - no more blank padding rows. |
| 0.1.50 | "Browse all albums in this category" fixed: correct category slug, multi-page windows, retry on empty payloads. |
| 0.1.49 | Now-playing codec/bitrate on the Daphile skin within ~2 seconds. |
| 0.1.48 | Late stream metadata announced to subscribed clients + persisted per track. |
| 0.1.47 | Play-queue rows carry title, duration and cover as soon as they are queued. |

---

## License

GPL-2.0 - see [LICENSE](LICENSE).

Ximalaya is a trademark of its respective owner. This project contains no code or assets
from Ximalaya's clients; protocol behaviour was reconstructed from public clients and
network traces for interoperability, and the plugin is distributed for personal use
only.
