# Family Tales

A premium, fully offline family tree and family history app for Android and iOS,
built with Flutter. No account, no server, no cloud — every record lives in an
encrypted SQLite database on the device, and photos live in the app's private
storage.

<p align="center"><img src="assets/branding/emblem.png" width="120" alt="Family Tales emblem"></p>

---

## 1. Quick start

Flutter 3.47 / Dart 3.13 or newer (tested with Flutter 3.47.8 stable).
On this machine Flutter lives at `D:\flutter\bin` (not on PATH), so either add it
to PATH or prefix the commands below with `D:\flutter\bin\`.

```bash
flutter pub get
```

```bash
dart run build_runner build --delete-conflicting-outputs
```

The second command regenerates the drift database code (`*.g.dart`). It is only
needed after changing `lib/core/database/tables.dart`; generated files are
already committed.

### Run

```bash
flutter run
```

Pick a device with `flutter devices`, e.g. `flutter run -d emulator-5554` or an
iPhone simulator on macOS.

### Tests

```bash
flutter test
```

Runs all unit and widget tests (domain logic, kinship, tree layout, backup /
restore / encryption / GEDCOM round-trips, statistics, search, duplicate
detection, screens).

```bash
flutter test integration_test/app_flow_test.dart -d emulator-5554
```

Runs the end-to-end flow on a device or emulator (see §10).

### Android builds

```bash
flutter build apk --release
```

```bash
flutter build appbundle --release
```

Outputs: `build/app/outputs/flutter-apk/app-release.apk` and
`build/app/outputs/bundle/release/app-release.aab`.
The release build is currently signed with the debug key so it runs out of the
box; add your own keystore in `android/app/build.gradle.kts` (`signingConfigs`)
before publishing.

### iOS builds (macOS + Xcode required)

```bash
cd ios && pod install && cd ..
```

```bash
flutter build ios --release
```

Open `ios/Runner.xcworkspace` in Xcode to set your Team / bundle identifier and
archive for the App Store. Minimum iOS version: 15.0.

> iOS could not be built in this environment (Windows). The iOS project is fully
> configured (Info.plist permissions, Face ID string, app icons, launch screen,
> privacy channel in `AppDelegate.swift`) but has not been compiled or run.

---

## 2. What's inside

| Area | Highlights |
|---|---|
| Onboarding | Splash, welcome hero, introduction, create tree, "about you" (photo, name, fuzzy birth date, gender), first members (father/mother/spouse/children/grandparents/later), privacy page (no sample data is ever added) |
| Home | Greeting pill, live family overview (members, generations, relationships, family lines, ancestors, completeness), quick actions, recent additions, upcoming occasions, recent memories; sections can be hidden/reordered |
| Family tree | Generated from the database; Focus / Descendants / Ancestors / Full / Compact layouts; pinch-zoom, pan, double-tap zoom, fit, reset, generation filter based on the generations actually in the tree, search, collapse/expand branches, reveal parents, navigate parents/children/partners, lineage highlighting, line styles for biological/adoptive/step/foster/guardian and ended partnerships, multiple trees |
| Members | Search, filters (living/deceased/archived/tags), sorting, multi-select bulk actions (branch, tag, archive, CSV export, trash) |
| Profiles | Digital biography: hero photo, relationship to the home person, lifespan/age, biography, life facts, derived family (parents, partners, children, siblings incl. half/step, grandparents, grandchildren), important dates, life events, photos, stories, branches & tags, custom fields, sources, private notes; share / PDF / delete |
| Add / edit member | One quick page: photo, first / last name, gender, birth date & place, living / passed away. Everything else (other names, death details, life story, custom fields, contact, privacy) sits behind "More details". Quick relative tiles (father, mother, husband, wife, son, daughter, brother, sister) plus 21 more relationship types, existing-person linking, other-parent choice, partner type & status |
| Relationships | Edit parent types and partnerships (type, status, dates, place), add/link/remove with undo; relationship finder with every distinct path |
| History | Events (21 types, multiple participants, photos, sources), family timeline (scopes, categories, decades), calendar (month/agenda), local reminders |
| Media | Gallery, albums, documents, viewer (zoom/swipe), crop, rotate, metadata, people/event tagging, storage usage |
| Stories & sources | Markdown-lite stories (reader + editor), sources with citations linked to people, events and partnerships |
| Insights & search | Computed statistics and charts, global search, branches, duplicate detection with manual merge, custom fields |
| Data | `.ftbackup` backup (optional AES-256-GCM), restore as new tree or replace, GEDCOM 5.5.1 import/export, JSON, CSV, PDF tree and profile, share sheet |
| Privacy | Encrypted database, PIN + biometric lock, auto-lock, app-switcher hiding, private people/fields/media, public-export filters, trash & recovery |

All 42 screens from the brief are implemented and routed (`lib/app/router.dart`).

---

## 3. Folder structure

```
lib/
  main.dart                    → app/bootstrap.dart
  app/
    app.dart                   MaterialApp.router, text scale & motion prefs, lock + reminders wrappers
    bootstrap.dart             opens the encrypted DB, loads settings, startup recovery screen
    router.dart                GoRouter + Routes (all paths)
    providers.dart             Riverpod providers (repositories, live data, family graph)
    settings.dart              AppPrefs (persisted preferences)
    navigation/app_shell.dart  floating bottom nav / tablet side rail
    theme/                     tokens (colours, gradients, type, spacing) + ThemeData
  core/
    database/                  drift tables + AppDatabase (+ generated code)
    models/                    FuzzyDate, enums
    repositories/              FamilyRepository, ContentRepository, SystemRepository
    security/                  SecureVault (keystore, PIN), app lock + lock screen
    services/                  AppPaths (file locations), MediaStorage (files, thumbnails, crop/rotate)
    widgets/                   design system (cards, pills, buttons, inputs, sheets, avatars…)
  features/
    family/domain/             FamilyGraph, KinshipCalculator, OccasionCalculator
    family_tree/               layout engine, painter, nodes, controls, tree screen
    onboarding/ dashboard/ members/ relationships/ events/ timeline/ calendar/
    gallery/ stories/ sources/ search/ reports/ branches/ trees/ backup/ settings/
assets/
  branding/                    emblem, logo, icon sources, splash images
  fonts/                       Inter (OFL), Phosphor icon fonts (MIT) + licences
test/                          unit + widget tests
integration_test/              end-to-end flow
docs/DEVELOPMENT.md            conventions for contributors
```

---

## 4. Dependencies

| Purpose | Package |
|---|---|
| State | flutter_riverpod 3 |
| Navigation | go_router 18 |
| Database | drift 2.35 (+ drift_dev, build_runner); `sqlite3` built with **SQLite3MultipleCiphers** via build hooks |
| Files | path_provider, path, file_picker, image_picker, image (thumbnails/crop/rotate in isolates), archive (zip) |
| Security | flutter_secure_storage (Android Keystore / iOS Keychain), local_auth (Face ID / fingerprint), cryptography (PBKDF2, AES-GCM), crypto (SHA-256) |
| Export / sharing | pdf, printing (offline preview), share_plus |
| Reminders | flutter_local_notifications, timezone, flutter_timezone |
| Utilities | intl, uuid, collection, flutter_localizations |
| Dev | flutter_launcher_icons, flutter_native_splash, integration_test, flutter_lints |

Fonts (Inter) and icons (Phosphor glyphs, as plain `IconData`) are bundled assets.
`phosphor_flutter` itself is **not** used: it subclasses `IconData`, which is a
`final` class in Flutter 3.47, so the fonts are vendored instead.

No analytics, ads, crash reporting, Firebase or any network SDK. Release
builds don't request the INTERNET permission (only the debug manifest adds it
for Flutter tooling).

---

## 5. Database schema

SQLite via drift, 28 tables, UUID v4 primary keys, foreign keys with
`ON DELETE CASCADE` for join tables, indexes on all lookup columns,
`created_at` / `updated_at` on every mutable row, `deleted_at` for trashable
rows, and a versioned `MigrationStrategy` (`schemaVersion = 1`).

| Table | Purpose |
|---|---|
| `family_trees` | Independent trees (name, description, home person, `is_example`) |
| `persons` | Names (first/middle/last/full/birth/nickname), gender, pronouns, birth/death facts, biography & life details, contact, privacy, archive, trash |
| `parent_child_links` | **Explicit** parent → child edges with type: biological, adoptive, step, foster, guardian, unspecified; optional dates |
| `partnerships` | Couples: marriage / civil union / partner / engaged; status current/divorced/separated/widowed/annulled/ended; dates, place |
| `family_branches`, `person_branches` | Named branches (root person + explicit members) |
| `family_events`, `event_persons` | Events with any number of participants (+ roles) |
| `media_assets`, `media_persons`, `media_events` | Photos & documents (relative file paths, thumbnails, metadata) and tags |
| `albums`, `album_media` | Albums |
| `stories`, `story_persons`, `story_events`, `story_media`, `story_tags` | Family stories and links |
| `sources`, `citations` | Evidence and fact-level citations (person, event, partnership) with confidence |
| `custom_fields`, `person_custom_values` | User-defined attributes (optionally private) |
| `reminders` | Custom reminders (birthdays/anniversaries are derived, not duplicated) |
| `tags`, `person_tags` | Tags |
| `deletion_records` | Trash log + JSON snapshots for undoing removed relationships |
| `backup_records` | Backup / restore history |
| `app_settings` | Key/value preferences |

**Dates.** Historical dates are `FuzzyDate` strings, never fake timestamps:
`EX:1950-03-12`, `EX:1950-03`, `EX:1950`, `ABT:1920`, `BEF:1920-03`,
`AFT:1900`, `BET:1920|1925`, `TXT:free text`. Missing parts are never invented —
year-only birthdays produce no reminders and are shown as "1950", "c. 1920",
"before Mar 1920", etc. The same model maps 1:1 to GEDCOM date syntax.

---

## 6. How relationships are calculated

Only two kinds of edges are stored: parent→child (typed) and partnerships.
Everything else is derived in `lib/features/family/domain/`:

* **FamilyGraph** builds adjacency maps and provides parents, children,
  partners, siblings (full / half / step / adoptive by comparing parent sets),
  grandparents, ancestors/descendants (BFS), connected components, shortest
  connection paths, cycle checks and generation numbers (constraint relaxation:
  partners share a generation, children sit one below parents, parentless
  in-laws are pulled down next to their children).
* **KinshipCalculator** finds the *lowest common ancestors* of A and B through
  blood/legal parent links (biological, adoptive, unspecified). With `a` and `b`
  the generation distances to that ancestor:
  `(0,1)` parent, `(0,n)` (n−2)× great-grandparent, `(1,1)` sibling,
  `(1,2)` aunt/uncle, `(1,n)` great-aunt/uncle, `(2,1)` niece/nephew,
  `(a≥2,b≥2)` **(min(a,b)−1)th cousin |a−b| times removed**; "half-" when the
  connecting siblings share only one parent. If several distinct ancestor pairs
  exist (double cousins, pedigree collapse) **every** relationship is returned
  with its own path — none is guessed. Labels use the person's gender
  (father/mother/parent…).
  Without a blood link it checks partnerships (husband, ex-wife, fiancée…),
  explicit step/foster/guardian links, then one marriage hop
  (son-in-law, sister-in-law, stepfather, cousin-in-law, uncle by marriage…),
  and finally reports "distant relative" with the connecting path.
* **Validation** (FamilyRepository) prevents self-links, duplicate links,
  parent/child cycles, partner+parent conflicts, ancestor–descendant
  partnerships and a third *biological* parent (step, adoptive, foster and
  guardian parents are unlimited).
* **RelationPlanner** turns "add Grandmother / Cousin / Nephew…" into the right
  parent/partner edges and asks "on which side?" when needed.

### Tree layout

`TreeLayoutEngine` (pure Dart, unit-tested) is a family-specific layered
(Sugiyama-style) layout: visible-set selection per view mode → layer assignment →
partner "units" that always stay adjacent → DFS seed ordering + barycentre
sweeps keeping the ordering with the fewest crossings → partner orientation
toward each partner's own family → Sugiyama's **priority method** for x-positions
(children centred under couples, parents above children) → orthogonal connectors
with staggered buses. 728 people lay out in ~55 ms. The canvas is an
`InteractiveViewer.builder` that only builds node widgets intersecting the
viewport; all connectors are painted by one `CustomPainter`.

---

## 7. Backup & restore

Backups are the only way data leaves the device — always user-initiated.

**`.ftbackup` archive** (ZIP):

* `manifest.json` — `format: family-tales-backup`, `formatVersion`, app and
  schema versions, creation time, trees, counts, and the **SHA-256 of every entry**.
* `data.json` — every row of every table for the selected trees (optionally
  settings).
* `media/<relative path>` — original photos/documents and thumbnails (optional).

**Encryption (optional, password-based)** — container `FTENC1`:
PBKDF2-HMAC-SHA256 (200 000 iterations, random 16-byte salt) → 256-bit key,
**AES-256-GCM** over 1 MiB chunks (nonce = 8 random bytes + chunk counter,
AAD binds the counter and a final-chunk flag, so truncation, reordering and
tampering are detected). Implemented with the maintained `cryptography`
package — no custom primitives. Large backups stream with progress and run off
the UI isolate.

**Restore** shows a preview first (file, date, trees, people, relationships,
photos), verifies hashes and schema version (newer schemas are rejected with a
clear message) and offers:

1. **Restore as new independent tree(s)** — every id is remapped to new UUIDs
   (including home person, profile photos, covers, citations, reminders) and
   media is copied into the new tree's folder.
2. **Replace an existing tree** — explicit destructive confirmation; the chosen
   tree's data is replaced in one transaction.

Nothing is ever overwritten silently; corrupt or incompatible files produce a
detailed error report.

**Other formats:** GEDCOM 5.5.1 import (into a new tree, with a report of
unsupported tags — unmapped lines are kept in the person's notes rather than
discarded) and export (with CONC/CONT, PEDI for adoptive/foster/step, events,
sources, privacy option for living people); JSON; CSV of members; PDF family tree
(vector, from the same layout engine) and PDF profiles — all with public-export
privacy filters (hide living people's birth dates, contact details, notes,
private fields, private people and media).

---

## 8. Local data security

* **Database encryption at rest:** SQLite3MultipleCiphers (bundled through the
  `sqlite3` package's build hooks, `hooks.user_defines.sqlite3.source: sqlite3mc`)
  using the **SQLCipher v4 compatible** scheme. The 256-bit key is generated on
  first launch and stored in **Android Keystore / iOS Keychain**
  (`flutter_secure_storage`, `first_unlock_this_device`). Settings → Privacy &
  security shows the live cipher status.
* **App lock:** 4-digit PIN (PBKDF2-HMAC-SHA256, 120 000 iterations, salted,
  constant-time compare, escalating cool-down after 5 failures), optional Face ID
  / fingerprint (`local_auth`, `FlutterFragmentActivity` on Android), auto-lock
  after a configurable time in the background.
* **App switcher privacy:** Android 13+ disables the Recents screenshot
  (`setRecentsScreenshotEnabled(false)`, FLAG_SECURE on older versions); on iOS a
  privacy cover is shown while inactive.
* **No automatic cloud copies:** Android `allowBackup=false` and data-extraction
  rules exclude everything; on iOS the data folder is marked
  `isExcludedFromBackup`. Use `.ftbackup` files to move between devices.
* If the keystore entry is ever lost, the app shows a recovery screen instead
  of crashing, and never deletes data without explicit confirmation.

---

## 9. Design system

Dark graphite canvas with a soft top-left key light, lit-edge gradient cards
(24 px radius), circular graphite icon buttons, mint `#86D8CA` accent used
sparingly, pill shapes, overlapping avatar stacks, striped progress bars,
dashed out-of-month calendar circles and Inter typography — translated from the
supplied reference. Light theme, system theme, five accent colours, text size
reduced motion and **full screen** (on by default: status and navigation bars
hidden until you swipe from an edge) are available in Appearance settings. Layouts are
edge-to-edge with safe-area insets (notches, punch holes, Dynamic Island,
gesture bars), keyboard-aware, and switch to a side rail on wide screens.
See `docs/DEVELOPMENT.md` for the component catalogue.

---

## 10. Testing

| Suite | What it covers |
|---|---|
| `test/domain` | FuzzyDate (all precisions, GEDCOM, ages), siblings, generations, cycle/biological-parent validation, 20+ kinship labels (cousins removed, half-siblings, in-laws, step, adoptive), layout invariants for every mode, collapse, 700+ person performance, relation planner, occasions, repository trash/merge |
| `test/backup` | Backup → restore round trip, encryption round trip and wrong password, export privacy, GEDCOM export → import |
| `test/domain/relation_planner_test.dart` | Every relationship type for every person (no self-links, always a connection), siblings of people without parents, generation-filter depth and layouts for every mode, settings round trip and corrupted-value fallback |
| `test/domain/regression_test.dart` | One test per fixed bug: trashed relatives still counted in loop / parent-limit checks, merge refusals and field preservation, same-year death dates, impossible dates, GEDCOM `FROM…TO`, ancestor loops in GEDCOM, in-law labels for unknown gender |
| `test/insights` | Statistics, search engine, branch membership, duplicate detection |
| `test/widget` | Design-system widgets, dashboard, members search, profile (derived relatives), tree rendering + selection, form validation, calendar grid, small-phone and tablet layouts without overflow; `feature_flows_test.dart`: adding a brother/sister when no parents are recorded (named and unnamed parents), double-tap Save, tree panel chips in light and dark, docked panel position, dynamic generation filter, onboarding without sample data, full-screen toggle |
| `integration_test` | Launch → onboarding creates tree, person, parents, spouse, child → tree shows 5 nodes, connections verified → edit via form → event, photo, story → encrypted backup → restart (DB reopened) → restore as new tree → all data verified |

### Latest results (Flutter 3.47.8, Windows host, Android 17 x86_64 emulator)

* `flutter analyze` – **no issues**.
* `flutter test` – **146 tests, all passing** (domain, regression, backup, insights, widget, feature flows).
* `integration_test/app_flow_test.dart` – **passed** on the emulator **with
  airplane mode enabled**.
* Release APK builds; `aapt dump permissions` shows **no INTERNET permission**.
* On-device check: the database file starts with cipher bytes (not
  `SQLite format 3`) and family names are not readable in the DB or WAL.
* Layout engine: 728 people laid out in ~55 ms (unit test).
* Cold start of the release build on the emulator: ~2.5 s to the dashboard.

Note: `flutter test integration_test/...` uninstalls the app afterwards (normal
for Flutter integration runs), which removes local data on that device.

---

## 11. Known limitations

* iOS has not been compiled or run (no macOS in this environment).
* Reminders are scheduled for the next 60 days whenever the app runs (iOS allows
  64 pending notifications); if the app isn't opened for two months, later
  reminders aren't scheduled until it is. Delivery uses inexact alarms.
* Reminders cover the active family tree.
* GEDCOM media (OBJE) references are reported but not imported (files aren't
  inside a GEDCOM).
* PDF/print preview uses the system print service when printing; generating and
  sharing PDFs is fully offline.
* Italic text in stories is synthesised (only upright Inter weights are bundled).
* The universal release APK is ~88 MB because it contains three ABIs; Play
  Store App Bundles (or `flutter build apk --split-per-abi`) deliver only the
  device's ABI.
* `android/gradle.properties` sets `kotlin.incremental=false` (avoids a Windows
  Kotlin incremental-cache corruption seen in plugin modules) and a 4 GB Gradle
  heap; adjust if your machine differs.
