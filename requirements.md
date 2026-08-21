# Cairn — Requirements (v0.1, rough)

> Name: **Cairn** — a small stack of stones hikers leave to mark a trail so they can find the way back. Each entry is a marker you leave for future-you to trace back to. Rename freely if it doesn't land.
> Platform: Flutter (Android + iOS). Fully offline. Free at launch, no paywall.

---

## 1. TL;DR

A private, offline, structured recorder for **audio and video entries** — think "voice memos + video diary + notes," but with types, tags, search, and aggressive-but-smart compression so a 10-minute clip doesn't eat half your phone. Everything stays on-device. No account, no cloud, no subscription.

---

## 2. The problem it solves

Phones make *recording* trivial and *finding* impossible.

Today, if you record a spoken thought, a practice run, or a moment worth keeping, it lands in one of two bad places:

- **The camera roll** — an undifferentiated, chronological dump. No types, no tags, no search by context, mixed in with screenshots and memes. Storage-devouring (a 30s clip can be 300–500 MB). You record something meaningful and never see it again.
- **A cloud journaling app** — gives you structure, but at the cost of privacy (your private reflections sitting on someone's server) and usually a subscription wall.

There is no **offline, private, structured, storage-efficient home for intentional audio/video entries.**

Cairn is that home: capture with intent (typed, tagged), retrieve without friction (filter + search), keep your device lean (smart compression), and never hand your inner life to the cloud.

**One-line positioning:** *A filing cabinet for your spoken and visual thoughts — private by default, tiny on disk.*

### Why this is defensible
Day One / Journey do text-first journaling with cloud + paywall. Native Voice Memos and the camera are typeless and unsearchable. Cairn's wedge is the intersection: **video-first + structured types + on-device search + real compression + zero cloud.** No single incumbent occupies that square.

---

## 3. Target user & jobs-to-be-done

Broad/all-purpose capture, so the taxonomy (not the audience) does the specializing. Representative jobs:

- "Leave myself a 30-second spoken note I can actually find next week."
- "Record my guitar practice every day and scan back through the last month."
- "Keep a private video diary that never touches the cloud."
- "Capture a quick how-to for myself before I forget the steps."
- "Log my kid's milestones without them ending up in a shared photo stream."

Design implication: capture must be **fast** (≤2 taps to recording) and organization must be **cheap** (type + tags applied in seconds, editable later).

---

## 4. Scope

### MVP (v1)
- Record audio and video entries in-app.
- Fixed entry types with per-type duration/quality validation (Section 6).
- Balanced automatic compression on save (Section 8).
- Tags (create, assign, rename, delete).
- Playback (audio + video) with basic scrubbing.
- Library screen: chronological list + grid.
- Filter by date range, time-of-day, type, tag(s), duration.
- Text search across title, notes, tags, type.
- Onboarding flow (Section 10).
- Local backup / export + import (Section 11).
- Entry detail: title, free-text note, type, tags, timestamps, location-optional-off-by-default.

### v1.x (fast follow)
- User-defined custom entry types.
- Favorites / pin.
- Collections/folders (manual grouping beyond tags).
- Basic in-app trim (start/end) before save.
- Widget / quick-record shortcut.

### Later / out of scope for now
- On-device transcription + transcript search (big value, own project — see Section 15).
- Cloud sync / cross-device.
- Sharing/export to social.
- Any paywall or IAP.
- Desktop targets (Windows/macOS) — not now, but keep the data layer portable.

---

## 5. Non-negotiable principles
1. **Offline-only.** No network calls at all in v1. This is a feature, not a limitation — state it loudly in onboarding.
2. **Private by default.** Location off by default. No analytics SDK, or a fully local/opt-in one at most.
3. **No data loss.** Offline means *you* are the only backup. Export/import is MVP, not later.
4. **Fast capture.** Cold-start to recording in ≤2 taps.
5. **Small on disk.** Compression is core to the value prop, not an afterthought.

---

## 6. Entry model & taxonomy

Two dimensions: **medium** (audio | video) and **type** (the structural intent). Type drives validation *and* the encoding profile — this is the key design idea: the type you pick decides both how long you're allowed to record and how it gets compressed.

### Fixed starter types (v1)

| Type | Medium | Max duration | Intent | Encoding bias |
|---|---|---|---|---|
| Quick Note | audio or video | 1 min | Fast thought to self | Smallest — talking-head/voice, low bitrate |
| Diary | audio or video | 5 min | Daily reflection | Balanced |
| Practice | audio or video | 20 min (configurable up) | Skill reps (music, speaking, movement) | Higher — detail/motion or audio fidelity matters |
| How-to | video | 10 min | Steps for future-you | Balanced, sharpness-leaning |
| Freeform | audio or video | 30 min (hard cap) | Catch-all | Balanced |

- Durations are **soft-validated at record time** (auto-stop + warning near the limit) and configurable in settings within sane bounds.
- Hard ceiling across all types (e.g. 30 min) to protect storage and encode time.

### Custom types (v1.x)
User defines: name, allowed medium(s), max duration, and picks a **base encoding profile** (Small / Balanced / High) rather than raw bitrate knobs. Keeps power without exposing codec internals.

### Validation rules (apply to both fixed and custom)
- Duration within type's max (auto-stop at limit).
- Medium must match type's allowed medium(s).
- Title optional; auto-title fallback = `{Type} · {date} {time}`.
- Tags optional but encouraged (nudge, not blocker).
- Free-text note optional.
- Reject save if the encode fails integrity check (Section 9).

---

## 7. Data model (recommend ObjectBox)

Recommend **ObjectBox** over Drift/SQLite here: media-heavy app with lots of list scrolling and reactive queries; ObjectBox's speed and Flutter-reactive queries fit well, and you've shipped it before. Drift is the fallback if you want raw SQL/FTS control (its FTS5 support is a genuine point in its favor for search — see Section 12 note).

Entities (rough):

**Entry**
- `id`
- `title` (nullable)
- `note` (nullable, free text)
- `medium` (enum: audio | video)
- `typeId` (FK → EntryType)
- `filePath` (relative, not absolute — see Section 9)
- `thumbnailPath` (nullable, video only)
- `durationMs`
- `fileSizeBytes` (post-compression)
- `originalSizeBytes` (nullable — nice for a "space saved" stat)
- `createdAt`, `updatedAt`
- `recordedAt` (may differ from createdAt if import)
- `width`, `height`, `codec`, `bitrate` (media metadata)
- `latitude`, `longitude` (nullable, off by default)
- `isFavorite`, `isDeleted` (soft delete → trash)
- tags: many-to-many → Tag

**EntryType**
- `id`, `name`, `allowedMedium`, `maxDurationMs`, `encodingProfile` (enum), `isSystem` (true for the fixed 5), `iconKey`, `colorKey`

**Tag**
- `id`, `name` (unique, case-insensitive), `colorKey`, `usageCount` (denormalized for sorting)

**AppSettings** (single row / key-value)
- default encoding profile, default type, location-capture on/off, hard duration cap, theme, backup reminders, etc.

Derive filter facets (available tags, type counts, date bounds) from queries rather than storing them.

---

## 8. Capture & compression (the important part)

### Why raw phone video is huge
Default capture is often 1080p or 4K at 30–60 fps with high bitrate (H.264 1080p30 ≈ 17–20 Mbps; 4K ≈ 50 Mbps). A diary/notes app needs none of that. The two levers are **resolution** and, more importantly, **bitrate** — plus using **HEVC (H.265)**, which gives roughly the same quality as H.264 at about half the size.

### Recommended engine: native, not FFmpeg
**Important 2026 context:** FFmpegKit was officially retired and its prebuilt binaries were pulled from Maven Central / CocoaPods / pub / npm on **April 1, 2025**. `ffmpeg_kit_flutter` is flagged unmaintained on pub.dev. A community continuation exists (**FFmpegKitNext**), but there's no clean drop-in successor.

For this app, **don't use FFmpeg at all.** Use **native platform compression** (MediaCodec on Android, VideoToolbox/AVFoundation on iOS). It's hardware-accelerated (fast, battery-friendly), adds zero binary bloat, and supports HEVC — which is exactly what "balanced, best-quality-per-byte" needs.

- **Primary candidates:** `flutter_compress` (native, target-size/bitrate/quality control, HEVC with H.264 fallback, live progress + cancellation) or `video_compress_kit` (MediaCodec/VideoToolbox). Evaluate both on real devices; API maturity and null-safety/current-SDK support should decide it.
- `video_compress` is the older, widely-used native option — stable but less actively developed; keep as fallback.
- **Only reach for FFmpegKitNext** if you later need something native APIs can't do (precise two-pass VBR, exotic filters). Not worth the binary size / maintenance risk for v1.

### Encoding profiles (balanced defaults)
Type → profile → target. These are starting points; validate perceptually on-device and tune.

| Profile | Video | Audio | ~10-min video | ~1-min audio |
|---|---|---|---|---|
| **Small** (Quick Note) | 720p, HEVC, ~1.5–2 Mbps, 30fps | AAC/Opus mono, 32–48 kbps | ~120–150 MB | ~0.3 MB |
| **Balanced** (Diary, How-to, Freeform) | 720p–1080p, HEVC, ~3–4 Mbps, 30fps | AAC stereo, 96 kbps | ~250–300 MB | ~0.8 MB |
| **High** (Practice) | 1080p, HEVC, ~5–6 Mbps, 30fps; audio-heavy practice can drop video res | AAC stereo 128 kbps (music) | ~400–450 MB | ~1 MB |

Reference point: a 30-second clip that was **500 MB raw** lands around **6–10 MB** at the Small profile. That "space saved" delta is worth surfacing in the UI.

### Design rules for compression
- **Type decides the profile automatically.** User never has to think about bitrate. Advanced users can override per-entry (Small/Balanced/High) in settings.
- **Bitrate is the primary size lever**, resolution secondary. For a talking-head note, 720p @ low bitrate is plenty; for movement practice, keep resolution but you can drop audio.
- **Compress off the UI thread**, after recording, with a visible progress indicator and cancel. Never block capture.
- **HEVC by default, H.264 fallback** for older devices that can't hardware-encode HEVC. Detect capability at runtime.
- **Keep original until the compressed file passes an integrity check**, then delete the original (Section 9). Optionally offer "keep original" toggle (off by default — defeats the purpose).
- **Generate a thumbnail** on save for video (first non-black frame or mid-point). Consider a 1–3s muted preview later.
- **Audio:** prefer AAC for compatibility; Opus if the chosen package supports it well (better at low bitrate). Voice = mono + low bitrate; music practice = stereo + higher.

---

## 9. Storage & file management
- Store media in the app's **private documents directory** (not the shared gallery — reinforces "offline & private" and avoids polluting the camera roll).
- **Store relative paths in the DB, resolve to absolute at runtime.** iOS app-container paths change across reinstalls/restores; storing absolute paths *will* break playback. This is a common footgun — get it right from day one.
- File naming: `{uuid}.{ext}` — never rely on user titles for filenames.
- **Integrity check** post-compression: verify the output is playable / non-zero / duration matches expected before deleting the original and committing the DB row. Wrap create-file + write-DB so a crash can't leave a row pointing at a missing file (or a file with no row).
- **Orphan cleanup:** background sweep for files with no DB row and rows with no file (log + offer repair).
- **Trash / soft delete:** `isDeleted` flag, purge after N days, with a "space used by trash" indicator.
- Surface **storage usage** (total, by type, by tag) in settings — it's both useful and on-brand for the compression story.

---

## 10. Onboarding (indie-app style)
Short, warm, benefit-led. 3–4 screens max, skippable, no account.

1. **What it is** — "Private recorder for the things you want to keep and actually find later." One line, one visual.
2. **Offline & private** — "Everything stays on your phone. No account, no cloud." (This is a selling point — lead with it.)
3. **Types & tags in 5 seconds** — show the capture-then-tag flow.
4. **Permissions, in context** — request mic/camera *at first record*, not upfront. Explain why in one sentence before the OS prompt (raises grant rate). Location is opt-in later, never on this screen.
5. End on a **"Record your first entry"** CTA that drops straight into capture.

Also: an empty-state on the library that teaches the first action rather than showing a blank screen.

---

## 11. Backup / export / import (MVP, not optional)
Offline = the user is the only backup. Data loss on reinstall/phone-loss would be fatal to trust.

- **Export:** single archive (zip) containing all media + a manifest (JSON) of entries, types, tags, metadata. Let user pick destination (Files app / Drive / SD — via system share sheet, still no in-app network).
- **Import:** restore from that archive; merge or replace, with conflict handling by entry id + timestamp.
- **Backup reminders:** gentle, dismissible nudge every N days or after M new entries.
- Keep the manifest schema **versioned** from v1 so future formats can migrate.
- Consider a "single entry export" (share one clip out) as v1.x.

---

## 12. Search & filter

**Filters (combinable):**
- Date range (calendar picker + presets: today, this week, this month, custom).
- Time-of-day bucket (morning/afternoon/evening/night) — you specifically wanted time.
- Type (multi-select).
- Tag(s) (multi-select, AND/OR toggle).
- Medium (audio/video).
- Duration band (e.g. <1 min, 1–5, 5+).
- Favorites.

**Search:** free-text across title, note, tag names, type name. Debounced, live results.

> Note on search tech: ObjectBox handles structured queries well; for fast substring/full-text over notes+titles it's serviceable at small scale. If text search becomes central (and especially once **transcription** lands — Section 15), **SQLite FTS5 (via Drift)** is materially better for full-text ranking. Decide the DB partly on how important content search is to you: no transcription → ObjectBox is fine; transcription-driven search as a headline feature → lean Drift+FTS5. Worth deciding *before* you build, since it's the expensive thing to swap later.

Persist the last-used filter set. Show active-filter chips with one-tap clear.

---

## 13. Screens / IA (rough)
- **Library** (home): list/grid toggle, filter bar, search, FAB → capture. Empty state teaches.
- **Capture**: pick type (remembers last), record, live duration + limit indicator, stop → review.
- **Review/Save**: preview, title, note, tags, type (editable), compression progress, save/discard.
- **Entry detail**: player, metadata, tags, note, edit, favorite, delete, "space saved" stat.
- **Filter sheet**: all facets in one bottom sheet.
- **Settings**: default type, default profile, location toggle, hard duration cap, storage usage, backup/export/import, theme, about.
- **Trash**: soft-deleted entries, restore/purge.
- (v1.x) **Type manager**: create/edit custom types.

---

## 14. Non-functional requirements
- **Performance:** library scroll stays smooth with 1000+ entries (lazy thumbnails, cached). Capture screen opens in <500ms warm.
- **Robustness:** survive mid-record interruption (call, kill) without corrupting DB; recover partial recordings where the platform allows.
- **Battery/thermal:** compression is hardware-accelerated and off main thread; don't compress on low battery without warning.
- **Privacy:** no network in v1; no third-party analytics, or local-only/opt-in. State this in the store listing.
- **Accessibility:** captions for controls, dynamic type, sufficient contrast, VoiceOver/TalkBack labels on record/play.
- **i18n-ready:** externalize strings even if launching English-only.
- **Theming:** light/dark; monochrome-friendly (matches your aesthetic leaning).

---

## 15. Notable future bet: on-device transcription
The single highest-value v2 feature: transcribe audio/video **on-device** (whisper.cpp / platform speech APIs) so entries become **text-searchable by content**, not just metadata. It turns "I know I recorded something about X" from impossible into instant. It's also fully compatible with the offline/private promise. Flagged as its own effort because it materially influences the **DB choice now** (see Section 12) — build the search layer so FTS can slot in.

---

## 16. Suggested build order (milestones)
1. **Capture + compress + store + play** one hardcoded type. Prove the compression numbers on real devices first — this is the riskiest assumption; validate before building UI around it.
2. Data model + library list + entry detail.
3. Types (fixed 5) + validation + tags.
4. Filter + search.
5. Onboarding + settings + storage usage.
6. Backup/export/import.
7. Polish, empty states, a11y → v1 launch.
8. Custom types, trim, favorites → v1.x.
9. On-device transcription → v2.

---

## 17. Open questions / risks
- **Compression reality-check:** the profile numbers above are targets — HEVC hardware-encode quality/speed varies a lot across Android OEMs. *Validate the price/quality on 3–4 real devices before committing the ladder.* (Milestone 1.)
- **HEVC playback/compatibility** on very old devices → keep H.264 fallback path tested.
- **iOS path portability** — relative-path discipline from day one (Section 9).
- **DB choice** hinges on how central content-search/transcription is to your vision (Section 12). Decide up front.
- **"Balanced" default** — confirm the exact target bitrates feel right to you once you see real clips; the table is a starting point, not gospel.
- Do you want a shared-gallery export path at all, or keep media strictly in-app? (Currently: in-app only, share-out on demand.)

---

*Rough v0.1 — meant as a starting skeleton, not a frozen spec. Tell me which sections to go deep on (data model, the compression pipeline, or the search/DB decision are the three with the most engineering weight).*