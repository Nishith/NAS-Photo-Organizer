# App Store Connect Metadata

Copy-paste-ready listing copy for Chronoframe's first Mac App Store submission. Character limits are noted so nothing gets truncated in App Store Connect. Update the three URLs once the site is hosted.

## Identity

| Field | Value |
| :--- | :--- |
| App name (30 char max) | `Chronoframe` |
| Subtitle (30 char max) | `Safe photo organizer` |
| Bundle ID | `com.nishith.chronoframe` |
| Primary category | Photo & Video |
| Secondary category | Utilities |
| Version | `1.1` |
| Copyright | `2026 Nishith Nand` |
| Age rating | 4+ (no objectionable content) |

Subtitle alternative (28 char): `Safe photo & video organizer`

## URLs

| Field | Value |
| :--- | :--- |
| Marketing URL | `https://chronoframe.app/` |
| Support URL | `https://chronoframe.app/support.html` |
| Privacy Policy URL | `https://chronoframe.app/privacy.html` |

## Promotional Text (170 char max)

Editable after release without a review. Good place for launch or update notes.

> Organize years of scattered photos into a clean date-based library without changing your originals — then remove duplicates safely to the Trash. On-device. No uploads.

## Description (4000 char max)

> Chronoframe is a safe photo and video organizer for people with years of media spread across phones, camera cards, old laptops, external drives, and backup folders. It builds a cleaner library in two practical ways — and it always shows you a plan before it changes anything.
>
> ORGANIZE
> Point Chronoframe at a messy folder and a destination, pick a date-based layout, and preview the plan. Chronoframe resolves each file's date from photo metadata, filename patterns, and the filesystem, and lets you review or correct uncertain dates before a single file is copied. Your source folder is read-only — nothing is moved, renamed, edited, or deleted.
>
> DEDUPLICATE
> Find exact copies by content, not filename, plus near-duplicates, burst groups, RAW+JPEG pairs, and Live Photo pairs. You decide what to keep. Selected files move to the macOS Trash, never a permanent delete, so you can always recover them.
>
> SAFE BY DESIGN
> • Originals stay untouched — Chronoframe only reads your source folder.
> • You approve the plan — Organize previews what will copy; Deduplicate previews what moves to Trash.
> • No overwrites — filename collisions get a distinct name instead of replacing a file.
> • Copies are verified — transfers are written atomically and re-hashed by default.
> • Receipts and revert — History records each run, and supported runs can be reverted when files still match the receipt.
>
> PRIVATE
> Chronoframe works only on folders you choose, processes everything on-device, and never uploads your library. There is no account, no analytics, no advertising, and no tracking. Cache, log, and receipt files are written inside the destination folder you select, so you can inspect or remove them anytime.
>
> REQUIREMENTS
> macOS 13.0 or later. Apple Silicon and Intel. Works fully offline.

## Keywords (100 char max, comma-separated, no spaces after commas)

> `duplicate,dedupe,photos,organizer,EXIF,cleanup,media,folder,backup,video,sort,library,metadata`

(94 characters. Apple counts spaces, so commas have no trailing space. Don't repeat the app name or subtitle words here — they're already indexed.)

## What's New (release notes for version 1.1)

> First public release of Chronoframe on the Mac App Store.
>
> • Organize scattered photos and videos into a clean date-based library without changing your originals.
> • Deduplicate exact copies, near-duplicates, bursts, RAW+JPEG pairs, and Live Photos — safely to the Trash.
> • Preview every plan before anything changes, with run history and revert.

## App Review Notes

> Chronoframe is a sandboxed macOS photo/video organizer. It only accesses folders the reviewer selects through the standard macOS folder picker. Organize copies files into a chosen destination and does not modify originals. Deduplicate moves reviewer-approved files to the macOS Trash only; it does not hard delete. The app runs entirely on-device, does not upload photos, and includes no analytics, telemetry, advertising, or crash-reporting services. Local cache, log, and receipt files are created in the selected destination to support preview, history, and revert. No sign-in or demo account is required.

## App Privacy (questionnaire answers)

These mirror `docs/PRIVACY_POLICY.md` and `ui/Resources/PrivacyInfo.xcprivacy`.

- Data collection: **No, we do not collect data from this app.**
- Tracking: **No.**
- Third-party SDKs (analytics/ads/crash): **None.**

If App Store Connect still asks per-category questions, answer "Not Collected" for every data type — Chronoframe does not transmit any data off-device.

## Pricing

- Tier: **USD 14.99** introductory (per `docs/APP_STORE_RELEASE.md`); move to **USD 19.99** after launch reviews accumulate.
- Availability: all territories (confirm before submitting).

## Hosting the URLs

The three URLs above come from the static site in `site/` (`index.html`, `support.html`, `privacy.html`). It is published to GitHub Pages by `.github/workflows/pages.yml` on every push to `main`, served at the custom domain **chronoframe.app** (`site/CNAME`).

To make the custom domain resolve, add these records at the registrar for `chronoframe.app`:

- **A** (apex `@`) → `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`
- **AAAA** (apex `@`) → `2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153`

Then set the Pages custom domain (`gh api -X PUT repos/Nishith/Chronoframe/pages -f cname=chronoframe.app`) and enable "Enforce HTTPS" once DNS resolves.

After the App Store listing is live, replace the Mac App Store button `href` in `site/index.html` with the live App Store product URL.
