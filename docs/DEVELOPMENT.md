# Family Tales – developer conventions

Read this before adding or changing a screen. The app is **fully offline**:
no network calls, no backend, no analytics, no runtime font/icon downloads.

## Toolchain

- Flutter is at `D:\flutter\bin\flutter.bat` (not on PATH). Dart: `D:\flutter\bin\dart.bat`.
- After changing `lib/core/database/tables.dart` run
  `D:\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs`.
- `D:\flutter\bin\dart.bat analyze lib` must report **No issues found**.

## Architecture (feature-first)

```
lib/
  app/            app root, router (Routes.*), providers, settings (AppPrefs), theme
  core/
    database/     drift tables + AppDatabase (SQLite, encrypted)
    models/       FuzzyDate (structured historical dates), enums
    repositories/ FamilyRepository, ContentRepository, SystemRepository
    services/     AppPaths (file locations), MediaStorage (files + thumbnails)
    security/     SecureVault (keystore, PIN), app lock
    widgets/      design system – import 'core/widgets/widgets.dart'
  features/<feature>/   screens + feature widgets + feature logic
  features/family/domain/  FamilyGraph, KinshipCalculator, OccasionCalculator
```

- Business logic stays out of widgets: put it in a repository or a plain Dart
  class under `features/<feature>/` (e.g. `gedcom/gedcom_exporter.dart`).
- State: Riverpod 3 (`flutter_riverpod`). Read data with the providers in
  `lib/app/providers.dart` (`peopleProvider`, `familyGraphProvider`,
  `eventsWithPeopleProvider`, `mediaProvider`, `storiesProvider`,
  `sourcesProvider`, `remindersProvider`, `albumsProvider`, …). They are
  drift streams, so UIs update automatically after every write.
- Writes: `ref.read(familyRepoProvider)`, `ref.read(contentRepoProvider)`,
  `ref.read(systemRepoProvider)`. Repositories throw `ValidationException`
  with a user-facing message – catch and show it with
  `showFTToast(context, e.toString(), error: true)`.
- Active tree: `ref.watch(activeTreeIdProvider)` (String?). Every query is per tree.
- Navigation: GoRouter; use `context.push(Routes.person(id))` etc. All paths
  are in `Routes` (`lib/app/router.dart`). Screens pushed with `context.push`
  sit above the bottom navigation.

## Data rules

- Dates of facts are `FuzzyDate` serialised strings (`FuzzyDate.tryParse`,
  `.serialize()`, `.format()`). Never invent missing day/month parts.
- Only parent→child (`ParentChildLinks`) and partner (`Partnerships`) edges
  are stored. Everything else is derived via `FamilyGraph` / `KinshipCalculator`.
- Deleting = moving to trash (`trashPerson`, `trashEvent`, `trashMedia`,
  `trashStory`, `trashSource`, `trashAlbum`, `trashTree`). Permanent deletion
  only happens from the Trash screen (`SystemRepository.purge`).
- Photos are files under `AppPaths.I.mediaDir(treeId)`; the DB stores
  relative paths. Resolve with `AppPaths.I.resolve(relPath)`. Prefer
  `thumbPath` for grids; use `Image.file(..., cacheWidth: …)`.
- Every destructive action needs confirmation (`showFTConfirm(destructive: true)`)
  and, where possible, an Undo toast.

## Design system (mandatory)

Visual reference: dark graphite, lit gradient cards, mint accent (#86D8CA),
circular graphite icon buttons, pill shapes, Inter typography, generous
spacing. **Do not** use default Material widgets for visible surfaces
(no `Card`, `ListTile`, `AppBar`, `ElevatedButton`, `FloatingActionButton`,
`Chip`, `TabBar`, `BottomNavigationBar`, `AlertDialog`).

Use (all from `core/widgets/widgets.dart`):

| Need | Widget |
|---|---|
| Page with header/back button | `FTPage(title:, actions: [FTIconButton(...)], body:)` |
| Card | `FTCard(child:, onTap:)` (lit gradient, 24 radius) |
| Pill surface / person row | `FTPill`, `PersonTile` (features/members/widgets/person_widgets.dart) |
| Inset icon circle | `IconBadge(icon:)` |
| Circular icon button | `FTIconButton(icon:, tooltip:, onTap:, accent:)` |
| Buttons | `FTButton(label:, onTap:)`, `FTButton.secondary`, `kind: FTButtonKind.danger` |
| Section title + "See all" | `SectionHeader('Title', action: 'See all', onAction:)` |
| Inputs | `FTTextField`, `FTSearchField`, `FTSelectField`, `FTSwitchRow`, `FTSegmented`, `FTChip`, `FuzzyDateField` |
| Settings rows | `FTListRow(title:, subtitle:, icon:, onTap:)` |
| Sheets & dialogs | `showFTSheet`, `showFTOptions`, `showFTConfirm`, `showFTTextPrompt`, `showFTToast` |
| People | `pickPerson`, `pickPeople`, `PersonAvatarFor`, `PersonChips` |
| Visual extras | `AvatarStack`, `StripedProgress`, `DashedCirclePainter`, `MetricTile`, `FTTag` |
| States | `EmptyState`, `LoadingView`, `ErrorView` |
| Entrance motion | wrap list items in `FadeSlideIn(index: i, child: …)` |

Tokens: `context.ft` (colours/gradients), `context.tx` (text styles:
display, headline, title, section, body, bodyStrong, label, caption, micro),
`Gap.*`, `Radii.*`, `Motion.*`, `context.pagePadding`, `context.reduceMotion`.
Icons: `AppIcons.*` only.

Layout rules:
- Horizontal padding `context.pagePadding`; wrap wide content in `ContentWidth`.
- Scrollable bodies end with bottom padding `FTPage.bottomInset(context)`
  (pushed screens) or `AppShell.contentInset(context)` (tab screens).
- Never hard-code screen sizes; use `LayoutBuilder` / `MediaQuery`.
- Text must survive 1.6× text scale: use `maxLines` + `overflow`, `Flexible`.
- Give every icon-only control a tooltip/semantic label.
- Respect `context.reduceMotion` for custom animations.
