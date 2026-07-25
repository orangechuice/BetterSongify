# CLAUDE.md

## What this project is

BetterSongify: a JavaScript extension for Spotify's UI with two build targets sharing one
source: a script injected into the desktop client (`xpui.spa`) and a Chrome
MV3 extension for the web player (`open.spotify.com` — same `xpui` codebase,
same DOM). It has **no API access and no framework** — every feature works by
scraping and manipulating Spotify's rendered DOM. Spotify's DOM is undocumented,
unversioned, and changes without notice (including A/B tests, so a breakage may
not reproduce on every machine).

**Default hypothesis for any regression report: Spotify changed their UI.**
Check the DOM contract table below before assuming a logic bug.

`README.md` covers the human-facing feature list and install flow; this file
covers what an agent needs to modify the code safely.

## Commands

```sh
npm run check          # ALWAYS run after editing src/ — syntax-checks, rebuilds dist, checks outputs
npm run build          # builds BOTH targets: dist/BetterSongify.js (desktop) + dist/chrome/ (extension)
npm run install:macos  # build + inject into Spotify.app (quits/relaunches Spotify)
npm run reinstall:macos # clean remove + fresh build/inject (install already updates in place; use for a clean slate)
npm run remove:macos   # restore stock Spotify
```

- Core logic lives in `src/index.js` (one IIFE, shipped verbatim to both
  targets — desktop gets a banner prepended, Chrome gets it as `content.js`).
  `src/chrome/` holds the extension-only files: `manifest.json` (MV3),
  `background.js` (translation-fetch relay — see Translation below), and
  `icons/` (PNGs referenced by the manifest; regenerate from
  `assets/icon.svg` via headless Chrome + `sips` if the icon changes). There
  are no build dependencies and no minification/obfuscation — outputs stay
  readable by design (Chrome Web Store policy also forbids obfuscated code).
  `dist/` is generated and gitignored — never edit it directly.
- `tools/build.js` also extracts the CSS template literal from
  `ensureBaseStyles` into `dist/chrome/styles.css` (manifest CSS can't be
  blocked by the page CSP; the runtime `<style>` injection remains as a
  harmless duplicate). The extraction matches the `style.textContent`
  assignment — keep that CSS in a single backtick-free template literal or
  the build throws.
- Chrome target: load `dist/chrome/` unpacked via `chrome://extensions`
  (Developer mode), test on `open.spotify.com`. After a rebuild, reload the
  extension there, then refresh the Spotify tab.
- There is no test suite and no lint config. Verification is manual: install
  into Spotify and watch the real client (see "Verifying changes").

## Architecture (src/index.js)

- **Settings**: `appSettings.<key>` is a property proxy over an in-memory
  object (`settingsData`) persisted as one JSON blob under
  `better_songify_settings` (write-through on set, so types survive as-is).
  Pre-rename settings blobs (`better_spotify_settings` and `spotify_lyrics_settings`)
  are carried over and deleted by `loadSettings`; pre-blob
  per-setting keys are folded in and deleted once by `migrateLegacySettings`.
  Adding a setting = add to `DEFAULTS` (+ a panel row if user-facing); never
  add to `LEGACY_SETTING_KEYS`.
- **Refresh loop**: a `MutationObserver` on the lyrics container plus a
  permanent 2-second interval (`startUiPlacementRetry`) drive the lyrics
  pipeline and panel-button placement. The interval exists because Spotify
  re-renders the player bar and now-playing view at will, silently discarding
  our injected button. Both funnel through `scheduleRefresh()` (rAF-debounced).
  Video enforcement has its own body-wide observer (`setupVideoObserver`) for
  low latency, with the same 2s interval as backstop — see the sticky video
  invariants below.
- **Song-change detection**: `getTrackKey()` = FNV-1a hash of target language
  + all lyric line texts. When it changes, translations/selection state reset.
  There is no event from Spotify for "track changed" — only the DOM changing.
- **Line decoration**: each lyric row gets a `.bs-lyric-note` annotation
  block (`data-bs-annotation="lyrics"`) appended, holding
  `.bs-note-pronunciation` / `.bs-note-meaning` spans;
  `renderLyricAnnotation` replaces the annotation's children in place, so
  re-decorating the same row stays idempotent (`restoreNativeLine` also
  strips `dataset.bsProcessed`/`bsSourceText` leftovers from older
  rewrite-style versions). The original and translated layers are
  independent toggles (`showOriginal` / `showTranslation`), pushed onto
  `body` as `data-bs-hide-original` / `data-bs-hide-translation` in
  `updateBodyMode()` — CSS does the show/hide, not JS (hidden annotations
  stay in the DOM). The panel guards against both being off:
  turning off the last text layer flips the other back on. Pre-July-2026
  blobs stored a three-way `currentMode` instead; `loadSettings` maps it
  to the pair once. Pronunciation (`showTransliteration`) is different:
  the pronunciation span is simply not rendered when off (re-render via
  `scheduleRefresh`), not CSS-hidden.
- **Translation**: unofficial Google Translate endpoint
  (`translate.googleapis.com/translate_a/single?client=gtx`, `dt=t` +
  `dt=rm` for romanization). Cached per language+text in
  `better_songify_translations_v3`, capped at 1000 entries. Failures return `null`
  and the line gets `.bs-caption-missing` (dimmed) — no error surfaces.
  **Transport differs per target** (`fetchTranslationPayload`): the desktop
  build fetches directly; in the Chrome build the content script is subject to
  the page's CORS (the endpoint sends no CORS headers), so it relays through
  `src/chrome/background.js` via `chrome.runtime.sendMessage`, which fetches
  under `host_permissions`. The branch is runtime-detected via
  `chrome.runtime?.id`; the worker only proxies the translate URL prefix.
- **Sticky video preference**: see behavioral invariants below.
- **Lyrics style / hide recommendations**: `applyLyricsAppearance()` (called
  from `updateBodyMode()`, i.e. on every refresh) pushes `lyricsScale`,
  `lyricsFont`, and `hideRecommendations` onto `body` as CSS vars
  (`--bs-lyrics-scale`, `--bs-lyrics-font`) and data attributes
  (`data-bs-font`, `data-bs-hide-recs`); static rules in `ensureBaseStyles`
  do the work. Size uses `zoom` (not `font-size`) so text and spacing scale
  together without knowing Spotify's responsive base size. Fonts are system
  stacks only (`LYRIC_FONTS`) — webfont loading would hit the page CSP.
- **Auto-open lyrics**: see behavioral invariants below.
- **Download**: a single "Download Lyrics" button in the settings panel saves
  a .txt (`exportTextFile`) whose contents follow the three layer toggles
  (original/pronunciation/translation). Generated fully locally. The old multi-format export
  view (Word/PDF, lyric-card PNG, html2pdf CDN dependency) was removed in
  July 2026 as unwanted.

## Spotify DOM contract

Every external coupling point, where it lives, and the symptom when Spotify
breaks it. All verified against the Spotify desktop client as of **July 2026**.
On the web player (`open.spotify.com`, July 2026) the following were verified
live: `lyrics-line`, `lyrics-button` (+ pointer-click requirement),
`context-item-info-title`/`-artist`, `recommended-track`. Notably
`lyrics-container` does **not** exist on the web player's `/lyrics` page —
only `lyrics-line`s — so container presence must never be the sole "lyrics
open" signal. Web-unverified couplings: the video toggle (the web player may
lack it entirely, which leaves sticky video silently inert there —
acceptable) and the translate endpoint relay. Verify before debugging a
web-only regression as a logic bug.

| Coupling | Code location | Feature it powers | Symptom when broken |
|---|---|---|---|
| `[data-testid="lyrics-container"]`, `[data-testid="lyrics-line"]` | `SELECTORS` | Entire translation pipeline | Lyrics render stock Spotify style; no translated/romaji spans; no errors |
| `[data-testid="lyrics-button"]` + player-bar selectors | `SELECTORS`, `findLyricsControlButton()` | "BetterSpotify" panel button placement | Button never appears; panel unreachable |
| `[data-testid="context-item-info-title"]` / `-artist` | `SELECTORS.nowPlayingTitle` / `-Artist` | .txt download header; track-change signal for auto-open lyrics | Downloads say "Unknown Song"; lyrics auto-open only once per session |
| `[data-testid="recommended-track"]` (one wrapper around the whole "Recommended" section of editable playlists, despite the singular name; fallback hook: `div.playlistRecommenderContainer` inside it) | `SELECTORS.playlistRecommendations` + a hardcoded copy in the `ensureBaseStyles` CSS (CSS can't read constants — keep in sync) | Hide Recommended Songs toggle | Recommended section reappears at the bottom of playlists despite the toggle; no errors. Verified on `open.spotify.com` July 2026, assumed identical on desktop |
| `[data-testid="lyrics-button"]` `disabled`/`aria-pressed`/`data-active` semantics; activates only on a full pointer-event sequence (`synthesizeClick`), plain `.click()` is ignored (web player, July 2026) | `enforceLyricsOpen()`, `synthesizeClick()`, lyrics branch of `handleVideoToggleClick()` | Auto-open lyrics (enforcement + click-capture mirror of the setting) | Lyrics view stops opening on track change, or (if "active" detection breaks) our click closes a lyrics view that was already open — watch for the view toggling off ~2s after a track change. If the `aria-pressed`/`data-active` semantics break, the click-capture mirror also inverts: opening lyrics manually would turn the setting off and vice versa |
| Button labeled "Switch to video" / "Switch to audio" (aria-label or text, **English only**) | `VIDEO_TOGGLE_PATTERNS`, `videoToggleKind()` | Sticky video preference; "Switch to audio" presence doubles as the "video is playing" gate for expand enforcement | Video reverts to audio on every track change again — the original bug resurfaces, silently; expand enforcement also stops firing |
| Buttons with aria-label "Expand Now Playing view" / "Minimize Now Playing view" (**English only**, no testid) | `NPV_EXPAND_PATTERNS`, `findVideoToggles()`, click-capture in `handleVideoToggleClick` | Expand music video (enforcement + capturing the user's own expand/minimize clicks as the preference) | Video stays in the sidebar despite the toggle, and manual expand/minimize stops updating the toggle; no errors. Verified on `open.spotify.com` July 2026, incl. that clicking expand while expanded is a no-op. Only verified for the NPV-header button — if the desktop video-overlay expand button carries a different aria-label, its clicks silently won't be captured |
| `main` element having zero width ⇔ expanded Now Playing view is covering it | `SELECTORS.mainView`, `isNowPlayingExpanded()` | Expand music video ("already expanded" signal + panel-off collapse gate) | Wrong-positive: toggle-off stops collapsing the view; wrong-negative: harmless redundant expand clicks (no-op). Verified on `open.spotify.com` July 2026 |
| Player-bar text-link button reading "Playing on <device>" while casting via Spotify Connect (**English only** — an encore `textLink`, no testid, no aria-label; text is the only hook) | `REMOTE_PLAYBACK_PATTERN`, `isPlayingRemotely()` | Remote-playback guard: suspends both video enforcements while playback is on another device | Enforcement fights audio/video switches made on the casting device (local clicks are relayed to it) — the July 2026 bug resurfaces. Same symptom on non-English clients, where the guard is silently off. Note the pill and expand buttons still render while casting (verified `open.spotify.com` July 2026), so their presence must never be used as a "playing locally" signal |
| `translate.googleapis.com` `gtx` endpoint response shape (`payload[0]`, index 3 = romanization) | `translateText()` | All translations | Every line dimmed (`untranslated`); cache stops growing |
| `xpui.spa` is a zip with `index.html` at root | `install-macos.sh` | Install itself | Installer errors "Failed to locate Spotify app layout" |

**Re-deriving a broken selector**: the web player at `open.spotify.com` shares
the same `xpui` codebase and `data-testid`s — inspect it in a normal browser
devtools instead of fighting the desktop client. Confirm in the desktop app
afterwards; also update the table above and the dated comment at the constant.

## Behavioral invariants (not derivable from the code)

### Sticky video preference

Spotify natively shows "We'll play video when available, from now on" but
actually reverts to audio on **every** track change. This extension makes the
choice genuinely sticky. Design decisions that must survive refactors:

- The preference (`preferVideo`, persisted in the settings blob) is set by capturing the
  user's clicks on **Spotify's own** toggle pill — there is deliberately no
  separate extension-only control path; the panel toggle is a mirror.
- `handleVideoToggleClick` ignores events with `isTrusted === false`. Our
  enforcement clicks the button programmatically; without this guard our own
  click would re-enter the preference setter (harmless today, a loop risk
  under refactor). Do not "simplify" this away.
- `enforceVideoPreference` has a 3-second debounce (`state.lastVideoAutoClick`)
  **and** a cap of 3 auto-clicks per track (`state.videoAutoClickKey`/
  `-Count`, reset when the panel toggle is re-enabled) so we never fight
  the user or a video that fails to load — an uncapped retry loop on a
  failing video makes Spotify pop its "can't play this right now" toast
  every ~3s for the whole track (observed July 2026).
- Audio preference is **intentionally not enforced** — audio is Spotify's
  default, so preferring audio means doing nothing.
- The label regex is English-only. Non-English clients silently lose this
  feature; a fix means adding localized labels or finding a stable testid.
- Enforcement is **event-driven**: `setupVideoObserver` watches
  `document.body` (childList + subtree) and clicks the pill the moment it
  renders. Because Spotify's DOM churns constantly (progress bar, animations),
  the callback must stay cheap — mutation bursts collapse into at most one
  button scan per animation frame via `scheduleVideoEnforce`. Never scan for
  the button per-mutation; that pattern must survive refactors.
- The 2s interval is a deliberate **backstop**, not dead code. Known failure
  mode and its diagnostic: if the audio-first blip on track change regresses
  from near-instant back to ~2 seconds, the observer path is broken — Spotify
  is rendering the pill somewhere the body observer can't see (shadow DOM, a
  portal/overlay outside `body`, or replacing `body` wholesale). The backstop
  keeps the feature working (slowly) in the meantime; the fix is to re-point
  `setupVideoObserver` at wherever the pill now renders. Do not remove the
  interval call when the observer looks sufficient.
- A **brief audio-first blip is irreducible** with this DOM approach: Spotify
  starts every track in audio, the pill must render before it can be clicked,
  and Spotify then swaps streams. Eliminating it entirely would require
  hooking Spotify's private player internals — deliberately avoided as far
  more fragile than DOM clicking. Don't chase the blip to zero.

### Expand music video

Spotify collapses the expanded Now Playing view when a video-less track
interrupts and never restores it on the next video track;
`preferVideoExpanded` compensates.

- Like sticky video, the preference is set by capturing the user's clicks on
  **Spotify's own** expand/minimize controls (`handleVideoToggleClick`, same
  isTrusted-guarded capture listener); the panel toggle is a mirror. Two
  deliberate asymmetries with the video-pill capture: (1) the click only
  counts as a preference signal **while a video is playing** — expanding
  album art on an audio-only track says nothing about videos; (2) a captured
  click also consumes `state.lastExpandAutoKey`, so a manual minimize can't
  be re-expanded by enforcement within the same track. Keyboard paths (Esc
  to close the expanded view) are **not** captured — only pointer clicks
  set the preference; enforcement still won't fight an Esc because the
  once-per-track key was already consumed when the view expanded.
- Targets the **in-app expanded view** ("Expand Now Playing view"), not
  `fullscreen-mode-button`. The first version shipped against OS fullscreen
  and was wrong twice over: users mean the expanded view, and the web
  player rejects untrusted fullscreen (user-activation rule) while the
  expanded view accepts synthesized clicks fine. Don't regress to the
  fullscreen button.
- **Once per track** (`state.lastExpandAutoKey`, keyed by
  `getNowPlayingKey()`): minimizing mid-track is respected, same philosophy
  as auto-open lyrics. Not continuous enforcement.
- The key is consumed on **observed expansion** (zero-width `main`) or a
  captured manual click — **never right after our own expand click**.
  Track-change re-renders (worst coming off the lyrics page, which also
  navigates) can swap the button out between scan and click, silently
  no-opping it; consuming on click stranded the video in the side panel
  for the whole track (July 2026 bug). Failed clicks retry on a 3s
  debounce (`state.lastExpandAutoClick`), capped at 3 per track
  (`state.expandAutoClickKey`/`-Count`) — if expansion is never observed,
  the zero-width-`main` signal is probably broken (web-verified only) and
  an unbounded click loop against an unknown desktop DOM is worse than
  giving up on the track. Esc-close is still respected because the
  expansion mutation triggers observe-and-consume long before a human can
  press Esc. Don't "simplify" back to consume-on-click.
- Gated on video actually playing: the "Switch to audio" pill must be
  present. The key is **not consumed** until then, so the enforcement
  naturally waits for sticky video to switch streams first.
- Clicking expand while already expanded is a **no-op** (verified July
  2026), so the zero-width-`main` "already expanded" check merely avoids
  pointless events; a wrong read is harmless. The panel-off path does need
  it though — the minimize button stays mounted (invisibly) even when not
  expanded, so collapsing without the gate would fire on a phantom button.
- Both video enforcements run off **one button scan**
  (`enforceVideoFeatures` → `findVideoToggles`, which also collects the
  expand/minimize buttons in the same pass) — the one-scan-per-frame rule
  from sticky video covers all of it; don't split these into separate
  scans.
- `synthesizeClick` must keep both halves: constructed pointer/mouse events
  **and** a trailing `element.click()`. Verified July 2026: the lyrics
  button only responds to the pointer events; the NPV expand/minimize
  buttons only respond to `element.click()` (a constructed "click"
  MouseEvent does nothing). Each handler style fires exactly once; adding a
  constructed "click" back would double-fire click-style handlers and
  revert toggles.

### Remote playback (Spotify Connect)

- While the player bar shows "Playing on <device>", **both video
  enforcements stand down** (`isPlayingRemotely()`, checked once per scan
  in `enforceVideoFeatures`): the local client is only a remote control,
  and the pill/expand buttons — which still render locally while casting —
  relay clicks to the casting device, so enforcement was fighting switches
  the user made there (July 2026 report).
- Remote switches deliberately do **not** update `preferVideo`: from this
  client's DOM, a remote switch-to-audio is indistinguishable from
  Spotify's own per-track auto-revert or a failed video load, so capturing
  it would corrupt the preference. Preferences change only via local
  trusted clicks (`handleVideoToggleClick` stays active while casting) or
  the panel.
- Auto-open lyrics stays active while casting (it's a local-only view),
  and skips the video-precedence gate — nothing will expand locally, so
  lyrics must not defer to a pill that enforcement will never act on.
- The guard fails **open**: if the label breaks (or the client is
  non-English), enforcement resumes fighting remote switches — see the
  contract table row.

### Auto-open lyrics

- Enforcement is **once per track**, keyed by player-bar `title|artist`
  (`state.lastLyricsAutoOpenKey`). If the user closes the lyrics view we do
  not reopen it for the rest of that track — never turn this into continuous
  enforcement, it would fight the user.
- The track-change signal must come from the player bar, **not**
  `getTrackKey()` — that hashes lyric lines, which only exist while the
  lyrics view is already open (chicken-and-egg).
- Like sticky video, the preference **mirrors trusted clicks on Spotify's
  own lyrics button** (`handleVideoToggleClick`, July 2026 — replaced the
  earlier deliberate no-capture design at the user's request): a click that
  opens lyrics turns auto-open on, one that closes them turns it off. The
  direction comes from the **pre-click** `aria-pressed`/`data-active` state,
  readable because the capture-phase listener runs before Spotify flips the
  button; a disabled button is ignored (it toggles nothing). A captured
  click also consumes the once-per-track key, so enforcement can't fight
  the choice mid-track. Non-click closes (Esc, navigating away) are not
  captured and only get the once-per-track behavior above.
- A disabled lyrics button (track has no lyrics) consumes the key without
  clicking. A missing button does **not** consume it — the player bar may
  simply not have rendered yet.
- The click must go through `synthesizeClick` (full
  pointerdown→…→click sequence): on the web player the lyrics button ignores
  plain `element.click()` (verified July 2026). The video pill keeps using
  `.click()` — that path is verified working on desktop and was deliberately
  left untouched.
- On the web player the opened `/lyrics` page has **no**
  `lyrics-container` testid (only `lyrics-line`s) — the button's
  `aria-pressed`/`data-active` state is the only reliable "already open"
  signal there. Don't reduce the open-check to container presence.
- Runs from the video-observer rAF path (riding its single button scan)
  plus the 2s interval as backstop. It was interval-only originally, but
  the video-precedence grace below needs frame-level pill detection to
  stay short — don't move it back to interval-only without also growing
  the grace.
- **Expanded video outranks lyrics**: when "Expand Music Video" is also on
  and the track's video will play expanded ("Switch to audio" pill present,
  or "Switch to video" present with sticky video on), the lyrics key is
  consumed without clicking — opening lyrics would cover/collapse the
  expanded view. Tracks without a video still auto-open, but only after a
  ~1.5s grace (`state.lyricsOpenDeferUntil`): the pill's absence is the
  only "no video" signal and it renders a beat after track change, so the
  wait is what lets video win the race. The grace is also the entire
  lyrics-open delay on video-less tracks (user-visible regression when it
  was 4s, July 2026), so keep it just above the pill's render latency —
  and if a slow pill does lose the race, the expand enforcement's retries
  recover by expanding over the open lyrics view. The grace does **not**
  consume the key, and only applies while both video preferences are on —
  with sticky video off, a video pill alone means nothing will
  auto-expand, so lyrics open normally.

### Lyrics pipeline

- Keying the track by concatenated line text (`getTrackKey`) means two songs
  with identical lyrics in the same language are treated as the same song
  (acceptable).
- `renderLyricAnnotation` must stay idempotent: Spotify recycles/re-renders
  rows, so the same line can be decorated many times per song.
- Never assume lyrics exist — most tracks in a session have no lyrics view
  open, and `refreshLyrics` early-returns; anything that must run regardless
  (like video enforcement) belongs in the 2s interval, not after that return.

### Cache & storage

- Persistent state lives under exactly two keys: the `better_songify_settings`
  blob (`SETTINGS_KEY`) and the `better_songify_translations_v3` cache
  (`CACHE_KEY`). "Restore Defaults" removes both, clears the pre-rename blobs
  and any legacy per-setting keys, and resets `settingsData` in memory.
- Legacy caches (`LEGACY_CACHE_KEYS`: v1, v2, the pre-rename
  `spotify_lyrics_translations_v3`, and `better_spotify_translations_v3`) are deleted on load, never migrated —
  caches refill on play. v3 entries are `[translated, roman]` tuples keyed
  `` `${lang}\x00${text}` `` — the separator in `src/index.js` is a literal
  raw NUL byte, which makes the file "binary" to grep (use `grep -a`).

## Verifying changes

1. `npm run check` (syntax + build, both targets).
2. Desktop: `npm run install:macos` — quits Spotify, injects, relaunches.
   Needs write access to `/Applications/Spotify.app`; may need `sudo`.
   Chrome: load/reload `dist/chrome/` unpacked, refresh the Spotify tab.
3. Watch the real client. For DOM debugging, prefer `open.spotify.com` in a
   browser. Note: Spotify auto-updates overwrite the injection — if the
   extension "disappeared", reinstall before debugging.
4. Video feature specifically: needs a track with a music video (and one
   without, to confirm no misbehavior), plus a track transition to see the
   auto-switch fire within ~2s. Expand toggle: expand the Now Playing view
   on a video track, let a video-less track interrupt, then a video track —
   the expanded view should restore within ~2s of the video starting. Also
   confirm minimizing mid-track is respected until the next track, and that
   manually expanding/minimizing while a video plays flips the "Expand
   Music Video" panel toggle (while no video plays, it must not).
5. Chrome translation path specifically: if every line renders dimmed on the
   web player but works on desktop, check the service worker console
   ("Inspect views" on the extension card) — the relay or `host_permissions`
   is the suspect, not the endpoint.
6. Hide Recommended Songs specifically: needs a playlist you own (the section
   only appears on editable playlists). Auto-open lyrics: change tracks with
   the lyrics view closed and expect it to open within ~2s; then close it
   mid-track and confirm it stays closed until the next track.

## Conventions

- Keep every Spotify-DOM coupling centralized in the existing constants
  (`SELECTORS`, `VIDEO_TOGGLE_PATTERNS`) with a dated comment — never
  inline a Spotify selector at a call site.
- When you change a coupling or add a new one, update the DOM contract table
  in this file in the same change.
