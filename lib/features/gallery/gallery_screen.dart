import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/services/app_paths.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import 'media_import.dart';
import 'media_tools.dart';
import 'media_widgets.dart';
import 'photo_actions.dart';

enum _Tab {
  photos('Photos'),
  albums('Albums'),
  documents('Documents');

  const _Tab(this.label);
  final String label;
}

/// Family gallery: photos (filterable by person and category), albums and
/// documents, all stored privately on the device.
class GalleryScreen extends ConsumerStatefulWidget {
  const GalleryScreen({super.key});

  @override
  ConsumerState<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends ConsumerState<GalleryScreen> {
  _Tab _tab = _Tab.photos;
  PhotoFilter _filter = const PhotoFilter();

  Future<void> _add() async {
    switch (_tab) {
      case _Tab.photos:
        await importPhotosFlow(context, ref);
      case _Tab.albums:
        final id = await createAlbumFlow(context, ref);
        if (id != null && mounted) context.push(Routes.album(id));
      case _Tab.documents:
        await importFilesFlow(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = context.pagePadding;
    final addLabel = switch (_tab) {
      _Tab.photos => 'Add photos',
      _Tab.albums => 'New album',
      _Tab.documents => 'Import documents',
    };
    return FTPage(
      title: 'Gallery',
      actions: [
        FTIconButton(icon: AppIcons.add, tooltip: addLabel, accent: true, onTap: _add),
      ],
      headerBottom: Padding(
        padding: EdgeInsets.fromLTRB(pad, Gap.xxs, pad, Gap.sm),
        child: ContentWidth(
          child: FTSegmented<_Tab>(
            values: _Tab.values,
            selected: _tab,
            labelOf: (t) => t.label,
            onChanged: (t) => setState(() => _tab = t),
          ),
        ),
      ),
      body: AnimatedSwitcher(
        duration: context.reduceMotion ? Duration.zero : Motion.fast,
        child: switch (_tab) {
          _Tab.photos => _PhotosTab(
              key: const ValueKey('photos'),
              filter: _filter,
              onFilter: (f) => setState(() => _filter = f),
              onAdd: _add,
            ),
          _Tab.albums => _AlbumsTab(key: const ValueKey('albums'), onCreate: _add),
          _Tab.documents => _DocumentsTab(key: const ValueKey('documents'), onImport: _add),
        },
      ),
    );
  }
}

/// "248 photos · 12 documents · 312 MB" line; opens the storage screen.
class _StorageLine extends StatelessWidget {
  const _StorageLine({required this.stats});
  final MediaStats stats;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    return FTPill(
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
      semanticLabel: 'Storage used: ${stats.label}. Open storage settings',
      onTap: () => context.push(Routes.storage),
      child: Row(
        children: [
          const IconBadge(icon: AppIcons.storage, size: 34),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(stats.label,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.caption.copyWith(color: c.text2)),
          ),
          Icon(AppIcons.forward, size: 16, color: c.text3),
        ],
      ),
    );
  }
}

// ================================================================= photos

class _PhotosTab extends ConsumerWidget {
  const _PhotosTab({super.key, required this.filter, required this.onFilter, required this.onAdd});
  final PhotoFilter filter;
  final ValueChanged<PhotoFilter> onFilter;
  final VoidCallback onAdd;

  Future<void> _choosePerson(BuildContext context, WidgetRef ref) async {
    if (filter.personId != null) {
      final r = await showFTOptions<int>(
        context,
        title: 'Filter by person',
        options: const [
          FTOption(0, 'Choose another person', icon: AppIcons.person),
          FTOption(1, 'Show everyone', icon: AppIcons.people),
        ],
      );
      if (r == null || !context.mounted) return;
      if (r == 1) {
        onFilter(PhotoFilter(category: filter.category));
        return;
      }
    }
    final id = await pickPerson(context, title: 'Photos of…');
    if (id != null) onFilter(PhotoFilter(personId: id, category: filter.category));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mediaProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e),
      data: (all) {
        final pad = context.pagePadding;
        final photos = [for (final m in all) if (m.kind == MediaKind.photo) m];
        final stats = MediaStats.of(all);
        if (photos.isEmpty) {
          return ListView(
            padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
            children: [
              ContentWidth(child: _StorageLine(stats: stats)),
              EmptyState(
                icon: AppIcons.photos,
                title: 'No photos yet',
                message: 'Bring old albums back to life: scan prints, add wedding photos or snapshots of today.',
                actionLabel: 'Add photos',
                onAction: onAdd,
              ),
            ],
          );
        }
        final byMedia = peopleByMedia(ref.watch(mediaPeopleProvider).value ?? const <MediaPerson>[]);
        final graph = ref.watch(familyGraphProvider).value ?? FamilyGraph.empty();
        final person = filter.personId == null ? null : graph[filter.personId!];
        final effective = person == null && filter.personId != null
            ? PhotoFilter(category: filter.category)
            : filter;
        final personScoped = PhotoFilter(personId: effective.personId).apply(photos, byMedia);
        final counts = <String, int>{};
        for (final m in personScoped) {
          final k = m.category?.trim().toLowerCase();
          if (k != null && k.isNotEmpty) counts[k] = (counts[k] ?? 0) + 1;
        }
        final shown = effective.apply(photos, byMedia);
        final ids = [for (final m in shown) m.id];
        return LayoutBuilder(builder: (context, cons) {
          final cols = gridColumnsFor(cons.maxWidth - pad * 2);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, Gap.sm),
                  child: ContentWidth(child: _StorageLine(stats: stats)),
                ),
              ),
              SliverToBoxAdapter(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.fromLTRB(pad, 0, pad, Gap.md),
                  child: Row(
                    children: [
                      FTChip(
                        label: person?.shortName ?? 'Everyone',
                        icon: AppIcons.person,
                        selected: person != null,
                        onTap: () => _choosePerson(context, ref),
                      ),
                      Container(
                        width: 1,
                        height: 22,
                        margin: const EdgeInsets.symmetric(horizontal: Gap.xs),
                        color: context.ft.border,
                      ),
                      FTChip(
                        label: 'All',
                        selected: effective.category == null,
                        onTap: () => onFilter(PhotoFilter(personId: effective.personId)),
                      ),
                      for (final cat in categoryChoices(photos)) ...[
                        const SizedBox(width: Gap.xs),
                        FTChip(
                          label: counts[cat.toLowerCase()] == null ? cat : '$cat · ${counts[cat.toLowerCase()]}',
                          selected: effective.category?.toLowerCase() == cat.toLowerCase(),
                          onTap: () => onFilter(PhotoFilter(
                            personId: effective.personId,
                            category: effective.category?.toLowerCase() == cat.toLowerCase() ? null : cat,
                          )),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (shown.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: EmptyState(
                    icon: AppIcons.filter,
                    title: 'No photos match',
                    message: person != null
                        ? 'No photos of ${person.shortName}${effective.category == null ? '' : ' in ${effective.category}'} yet.'
                        : 'Nothing in ${effective.category ?? 'this category'} yet. Assign categories when editing a photo.',
                    compact: true,
                  ),
                )
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(pad, 0, pad, FTPage.bottomInset(context)),
                  sliver: SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final m = shown[i];
                        return FadeSlideIn(
                          index: i % (cols * 6),
                          offset: 10,
                          child: MediaThumb(
                            media: m,
                            onTap: () => context.push(Routes.media(m.id), extra: ids),
                            onLongPress: () => showPhotoActions(context, ref, m, contextIds: ids),
                          ),
                        );
                      },
                      childCount: shown.length,
                    ),
                  ),
                ),
            ],
          );
        });
      },
    );
  }
}

// ================================================================= albums

class _AlbumsTab extends ConsumerWidget {
  const _AlbumsTab({super.key, required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(albumsProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e),
      data: (albums) {
        final pad = context.pagePadding;
        final byId = ref.watch(mediaByIdProvider);
        final entries = ref.watch(albumEntriesProvider).value ?? const <AlbumMediaEntry>[];
        final existing = {for (final a in albums) a.name.trim().toLowerCase()};
        final suggestions = [
          for (final n in kSuggestedAlbums)
            if (!existing.contains(n.toLowerCase())) n,
        ];
        return LayoutBuilder(builder: (context, cons) {
          final cols = gridColumnsFor(cons.maxWidth - pad * 2, target: 168, min: 2, max: 5);
          final rows = (albums.length / cols).ceil();
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
            itemCount: 1 + (albums.isEmpty ? 1 : rows),
            itemBuilder: (context, i) {
              if (i == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(
                        albums.isEmpty ? 'Albums' : '${albums.length} ${albums.length == 1 ? 'album' : 'albums'}',
                        action: 'New album',
                        onAction: onCreate,
                      ),
                      if (suggestions.isNotEmpty) ...[
                        Text('Quick start', style: context.tx.caption),
                        const SizedBox(height: Gap.xs),
                        Wrap(
                          spacing: Gap.xs,
                          runSpacing: Gap.xs,
                          children: [
                            for (final s in suggestions)
                              FTChip(
                                label: s,
                                icon: AppIcons.add,
                                selected: false,
                                onTap: () => createAlbumFlow(context, ref, name: s),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                );
              }
              if (albums.isEmpty) {
                return EmptyState(
                  icon: AppIcons.album,
                  title: 'No albums yet',
                  message: 'Group photos into albums such as weddings, trips or a grandparent’s life.',
                  actionLabel: 'Create album',
                  onAction: onCreate,
                );
              }
              final r = i - 1;
              return Padding(
                padding: const EdgeInsets.only(bottom: Gap.lg),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var c = 0; c < cols; c++) ...[
                      if (c > 0) const SizedBox(width: Gap.md),
                      Expanded(
                        child: r * cols + c < albums.length
                            ? Builder(builder: (context) {
                                final a = albums[r * cols + c];
                                final ids = albumMediaIds(a.id, entries, byId);
                                return FadeSlideIn(
                                  index: r * cols + c,
                                  child: AlbumCard(
                                    album: a,
                                    cover: albumCover(a, ids, byId),
                                    count: ids.length,
                                    onTap: () => context.push(Routes.album(a.id)),
                                  ),
                                );
                              })
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        });
      },
    );
  }
}

/// Album tile: stacked "prints" behind a rounded cover, name and count.
class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, required this.cover, required this.count, this.onTap});
  final Album album;
  final MediaAsset? cover;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    Widget layer(double inset, double top, double alpha) => Positioned(
          left: inset,
          right: inset,
          top: top,
          height: 24,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.surfaceHigher.withValues(alpha: alpha),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(Radii.md)),
              border: Border.all(color: c.border),
            ),
          ),
        );
    return Pressable(
      onTap: onTap,
      semanticLabel: '${album.name}, $count ${count == 1 ? 'photo' : 'photos'}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 0.95,
            child: Stack(
              children: [
                layer(18, 0, 0.45),
                layer(9, 5, 0.75),
                Positioned.fill(
                  top: 10,
                  child: FTCard(
                    padding: EdgeInsets.zero,
                    radius: Radii.md,
                    child: LayoutBuilder(builder: (context, cons) {
                      if (cover == null) {
                        return const Center(child: IconBadge(icon: AppIcons.album, size: 52));
                      }
                      return Image.file(
                        File(cover!.thumbAbsolutePath),
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        cacheWidth: (cons.maxWidth * dpr).round().clamp(64, 1200),
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const Center(child: IconBadge(icon: AppIcons.album, size: 52)),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Gap.sm),
          Text(album.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
          const SizedBox(height: 2),
          Text('$count ${count == 1 ? 'photo' : 'photos'}',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: context.tx.caption),
        ],
      ),
    );
  }
}

// ============================================================== documents

enum _DocAction { view, share, rename, trash }

class _DocumentsTab extends ConsumerWidget {
  const _DocumentsTab({super.key, required this.onImport});
  final VoidCallback onImport;

  Future<void> _actions(BuildContext context, WidgetRef ref, MediaAsset m) async {
    final a = await showFTOptions<_DocAction>(
      context,
      title: m.displayTitle,
      options: [
        if (m.isImage) const FTOption(_DocAction.view, 'View', icon: AppIcons.eye),
        const FTOption(_DocAction.share, 'Open or share',
            icon: AppIcons.share, subtitle: 'Open in another app or send a copy'),
        const FTOption(_DocAction.rename, 'Rename', icon: AppIcons.edit),
        const FTOption(_DocAction.trash, 'Move to trash', icon: AppIcons.trash, danger: true),
      ],
    );
    if (a == null || !context.mounted) return;
    switch (a) {
      case _DocAction.view:
        context.push(Routes.media(m.id), extra: [m.id]);
      case _DocAction.share:
        await shareMediaFile(context, m);
      case _DocAction.rename:
        final name = await showFTTextPrompt(context, title: 'Rename document', label: 'Name', initial: m.displayTitle);
        if (name == null) return;
        try {
          await ref.read(contentRepoProvider).updateMedia(m.id, MediaAssetsCompanion(caption: Value(name)));
        } catch (e) {
          if (context.mounted) showFTToast(context, friendlyError(e), error: true);
        }
      case _DocAction.trash:
        await trashMediaFlow(context, ref, m);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(mediaProvider);
    return async.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(error: e),
      data: (all) {
        final pad = context.pagePadding;
        final docs = [for (final m in all) if (m.kind == MediaKind.document) m];
        final stats = MediaStats.of(all);
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, FTPage.bottomInset(context)),
          itemCount: 1 + (docs.isEmpty ? 1 : docs.length),
          itemBuilder: (context, i) {
            if (i == 0) {
              return ContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: Gap.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _StorageLine(stats: stats),
                      if (docs.isNotEmpty) ...[
                        const SizedBox(height: Gap.md),
                        SectionHeader('Certificates, letters & scans', action: 'Import', onAction: onImport),
                      ],
                    ],
                  ),
                ),
              );
            }
            if (docs.isEmpty) {
              return EmptyState(
                icon: AppIcons.document,
                title: 'No documents yet',
                message: 'Keep certificates, letters, wills and scans together with your family history.',
                actionLabel: 'Import documents',
                onAction: onImport,
              );
            }
            final m = docs[i - 1];
            return ContentWidth(
              child: Padding(
                padding: const EdgeInsets.only(bottom: Gap.sm),
                child: FadeSlideIn(
                  index: i,
                  child: _DocumentCard(
                    media: m,
                    onTap: () => _actions(context, ref, m),
                    onShare: () => shareMediaFile(context, m),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({required this.media, required this.onTap, required this.onShare});
  final MediaAsset media;
  final VoidCallback onTap;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final sub = '${formatBytes(media.sizeBytes)} · Added ${DateFormat.yMMMd().format(media.createdAt)}';
    return FTCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      onTap: onTap,
      onLongPress: onTap,
      semanticLabel: '${media.displayTitle}, $sub',
      child: Row(
        children: [
          IconBadge(icon: media.kindIcon, size: 44),
          const SizedBox(width: Gap.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(media.displayTitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.bodyStrong),
                const SizedBox(height: 2),
                Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.caption),
              ],
            ),
          ),
          FTIconButton(icon: AppIcons.share, tooltip: 'Share ${media.displayTitle}', size: 40, onTap: onShare),
        ],
      ),
    );
  }
}
