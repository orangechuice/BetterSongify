# BetterSongify

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-Support-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/orangechuice)

A set of quality-of-life improvements for Spotify's UI: lyric translation and transliteration, sticky music-video preferences, lyrics display controls, and playlist cleanups. It ships in two forms: a script injected into the Spotify desktop app, and a Chrome extension for the web player at `open.spotify.com`.

## Features

- **Translated lyrics** — adds translated text below each lyric line using Google Translate.
- **Transliteration / romanization** — shows romanized readings when available (e.g. for Japanese, Korean, Chinese).
- **Dual-language display** — toggle between original-only, translated-only, or side-by-side views.
- **Lyrics style** — text size and font controls for the lyrics view.
- **Auto-open lyrics** — opens the lyrics view once per track change.
- **Sticky music video** — makes "switch to video" genuinely persist across track changes, and optionally re-expands the Now Playing view when a video plays.
- **Hide Recommended Songs** — removes the "Recommended" section from your own playlists.
- **Settings panel** — all of the above via a side panel inside Spotify.
- **Download lyrics** — save the currently displayed lyrics combination (original, pronunciation, translation) as a plain-text file.

Control panel screens:

<img width="364" height="855" alt="image" src="https://github.com/user-attachments/assets/0fd1caae-f955-441f-8ed9-024bb7b553c0" />

Lyric translation screens: 
<img width="1321" height="850" alt="image" src="https://github.com/user-attachments/assets/1910e2c5-b474-460e-8d4c-dc1a2246932c" />

## How It Works

`src/index.js` is a browser script that runs inside Spotify's UI — injected into the desktop app's `xpui.spa` by the installer, or loaded as a content script on `open.spotify.com` by the Chrome extension. Both targets share the same source; the desktop and web players share the same underlying Spotify codebase (`xpui`), so the same DOM selectors work in both. It does **not** call a private Spotify lyrics API — it works entirely with the lyrics Spotify has already rendered on screen.

### DOM Integration

The script locates Spotify's lyrics view using selectors like `[data-testid="lyrics-container"]` and `[data-testid="lyrics-line"]`. A `MutationObserver` watches lyric rows so the script re-runs when Spotify changes songs, navigates pages, or lazily renders additional lines. Each lyric line is read from the DOM, assigned a stable per-song line ID, and rewritten with source, transliterated, and translated spans.

### Translation

Translations are fetched from Google Translate's public web endpoint:

```
https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=<target>&dt=t&dt=rm&q=<line>
```

| Parameter | Purpose |
|-----------|---------|
| `sl=auto` | Auto-detect source language |
| `tl=<target>` | Target language from BetterSongify settings |
| `dt=t` | Return translated text |
| `dt=rm` | Return romanization / transliteration data |

Results are cached in `localStorage` under `better_songify_translations_v3`, keyed by target language + source text. User settings (language, view mode, romanization, video preference) are stored as a single JSON object under `better_songify_settings`; settings from older versions (including legacy `better_spotify_settings` and `spotify_lyrics_settings` blobs) are migrated in automatically.

In the Chrome extension, the translation request is relayed through the extension's background service worker: content scripts are bound by the page's CORS policy and the translate endpoint sends no CORS headers, so the worker performs the fetch under the extension's `host_permissions`. The desktop build fetches directly. Settings and caches are per-environment — the desktop app and the web player each have their own `localStorage`.

### Downloads

The "Download Lyrics" button in the settings panel saves a .txt generated locally in the browser — no external libraries. Its contents mirror the current view: the original line, plus pronunciation and/or translation when those are enabled. Song metadata for the file header is read from Spotify's rendered UI.

## Getting Started

### Prerequisites

- **Node.js** (any recent LTS version).
- For the desktop target: **macOS** with the Spotify desktop app installed.
- For the web target: **Google Chrome** (or any Chromium browser that loads unpacked extensions).

### Build

```sh
npm run build        # Build both targets: dist/BetterSongify.js and dist/chrome/
npm run check        # Syntax-check sources, rebuild, then syntax-check outputs
```

There are no dependencies to install — both targets are plain copies of the readable source in `src/`, assembled by `tools/build.js`.

### Install into Spotify (macOS)

```sh
./install-macos.sh install    # Build, inject into Spotify's xpui.spa
./install-macos.sh reinstall  # Remove any existing injection, then build and inject fresh
./install-macos.sh remove     # Remove the injection and restore xpui.spa
```

Or via npm scripts:

```sh
npm run install:macos
npm run reinstall:macos
npm run remove:macos
```

`install` already updates an existing installation in place; use `reinstall` when
you want a clean slate — it fully strips the old injection (script tag, bundle,
and backups) before building and injecting the current version.

### Load into Chrome (web player)

1. Run `npm run build` — the extension is emitted to `dist/chrome/`
   (`manifest.json`, `content.js`, `background.js`, `styles.css`, `icons/`).
2. Open `chrome://extensions` in Chrome.
3. Enable **Developer mode** (toggle in the top-right corner).
4. Click **Load unpacked** and select the `dist/chrome/` directory.
5. Open (or reload) `open.spotify.com`, play a track, and open the lyrics
   view — the BetterSongify button appears next to Spotify's lyrics control
   in the player bar.

After rebuilding, click the reload (circular arrow) icon on the extension's
card in `chrome://extensions`, then refresh the Spotify tab.

> **Note:** load-unpacked is the supported install path. The extension is not
> published to the Chrome Web Store; doing so would require a developer
> account, a store listing with a privacy policy (lyric text is sent to the
> Google Translate endpoint), and passing review.

## Project Layout

```
src/
  index.js              Extension source (readable, single-file, shared by both targets)
  chrome/
    manifest.json       Chrome extension manifest (MV3)
    background.js       Service worker that proxies translation fetches (CORS)
    icons/              Extension icons (PNG, rendered from assets/icon.svg)
tools/
  build.js              Build script — writes both dist targets
dist/                   (gitignored)
  BetterSongify.js      Built bundle injected into the Spotify desktop app
  chrome/               Unpacked Chrome extension for open.spotify.com
assets/
  BetterSongify.svg     Project wordmark
  icon.svg              Square icon source (rasterized into src/chrome/icons/)
install-macos.sh        macOS installer / remover for Spotify.app
package.json            npm scripts and project metadata
```

## Known Limitations

- **Spotify UI changes** — the extension depends on Spotify's DOM structure and `data-testid` attributes. Selector renames, shadow DOM, canvas-rendered lyrics, or aggressive row recycling can break it.
- **Button placement** — the BetterSongify button is anchored next to Spotify's lyrics/microphone control in the now-playing bar. Layout or attribute changes there require a selector update.
- **Google Translate** — the endpoint is unofficial. It may change response shape, rate-limit, block requests, or omit transliteration data without notice.
- **Downloads** — saving the .txt relies on the file-picker/download APIs available inside Spotify's shell; changes there can break it.
- **Spotify updates** — desktop app updates overwrite `xpui.spa`, removing the injected script. Re-run the installer after updating Spotify.
- **Web player differences** — the DOM selectors were verified against the desktop client; the web player shares the same codebase but deploys more frequently and may be A/B-tested differently. In particular, the music-video toggle may not exist on the web player, in which case the "Prefer Music Video" feature is silently inactive there.

## Support

If you enjoy BetterSongify and find it helpful, consider supporting development on [Ko-fi](https://ko-fi.com/orangechuice)!

[![Support on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/orangechuice)

## Disclaimer

- This project is **not affiliated with, endorsed by, or supported by Spotify or
  Google**. "Spotify" is a trademark of Spotify AB; it is used here only to
  describe what the project does.
- The desktop install works by modifying local Spotify application files on
  your machine. Doing so may violate Spotify's Terms of Use. **Use at your own
  risk** — you are responsible for ensuring you are permitted to inspect and
  modify those files in your environment.
- Translations use an unofficial, undocumented Google Translate endpoint. Its
  use is not sanctioned by Google, and it may be rate-limited, blocked, or
  changed without notice.
- The software is provided as-is, without warranty of any kind. See
  [LICENSE](LICENSE).

## License

[MIT](LICENSE)
