import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/widgets/widgets.dart';
import 'media_import.dart';
import 'media_tools.dart';
import 'media_widgets.dart';
import 'photo_actions.dart';

enum _AddSource { gallery, import }

enum _AlbumAction { edit, delete }

/// One album: cover banner, description and its photos. Photos can be added
/// from the gallery or imported, removed, and one chosen as the cover.
class AlbumDetailScreen extends ConsumerWidget {
  const AlbumDetailScreen({super.key, required this.albumId});
  final String albumId;

  Future<void> _addPhotos(BuildContext context, WidgetRef ref, List<String> current) async {
    final src = await showFTOptions<_AddSource>(
      context,
      title: 'Add photos',
      options: const [
        FTOption(_AddSource.gallery, 'Choose from gallery',
            icon: AppIcons.photos, subtitle: 'Photos already in Family Tales'),
        FTOption(_AddSource.import, 'Import new photos',
            icon: AppIcons.camera, subtitle: 'Camera, photo library or files'),
      ],
    );
    if (src == null || !context.mounted) return;
    switch (src) {
      case _AddSource.gallery:
        final picked = await pickMedia(context, title: 'Add to album', exclude: current.toSet());
        if (picked == null || picked.isEmpty) return;
        try {
          await ref.read(contentRepoProvider).addToAlbum(albumId, picked);
          if (context.mounted) {
            showFTToast(context, picked.length == 1 ? 'Photo added' : '${picked.length} photos added');
          }
        } catch (e) {
          if (context.mounted) showFTToast(context, friendlyError(e), error: true);
        }
      case _AddSource.import:
        await importPhotosFlow(context, ref, albumId: albumId);
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Album album) async {
    final r = await showFTSheet<(String, String)>(
      context,
      title: 'Edit album',
      builder: (_) => _AlbumForm(name: album.name, description: album.description ?? ''),
    );
    if (r == null) return;
    try {
      await ref.read(contentRepoProvider).updateAlbum(album.id, name: r.$1, description: r.$2);
      if (context.mounted) showFTToast(context, 'Album updated');
    } catch (e) {
      if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Album album, int count) async {
    final ok = await showFTConfirm(
      context,
      title: 'Delete “${album.name}”?',
      message: count == 0
          ? 'The album moves to the trash. You can restore it from there.'
          : 'The album moves to the trash. Its $count ${count == 1 ? 'photo stays' : 'photos stay'} in your gallery – only the grouping is removed.',
      confirmLabel: 'Delete album',
      destructive: true,
      icon: AppIcons.trash,
    );
    if (!ok || !context.mounted) return;
    final repo = ref.read(contentRepoProvider);
    final done = await trashWithUndo(
      context,
      ref,
      type: TrashEntity.album,
      id: album.id,
      trash: () => repo.trashAlbum(album.id),
      message: 'Album moved to trash',
    );
    if (done && context.mounted) context.pop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final albumsAsync = ref.watch(albumsProvider);
    Album? album;
    for (final a in albumsAsync.value ?? const <Album>[]) {
      if (a.id == albumId) album = a;
    }
    if (album == null) {
      return FTPage(
        title: 'Album',
        body: albumsAsync.isLoading
            ? const LoadingView()
            : (albumsAsync.hasError
                ? ErrorView(error: albumsAsync.error!)
                : const EmptyState(
                    icon: AppIcons.album,
                    title: 'Album not found',
                    message: 'It may have been moved to the trash.',
                  )),
      );
    }
    final a = album;
    final byId = ref.watch(mediaByIdProvider);
    final entries = ref.watch(albumEntriesProvider).value ?? const <AlbumMediaEntry>[];
    final ids = albumMediaIds(a.id, entries, byId);
    final photos = [for (final id in ids) byId[id]!];
    final cover = albumCover(a, ids, byId);
    final pad = context.pagePadding;
    return FTPage(
      title: a.name,
      actions: [
        FTIconButton(
          icon: AppIcons.add,
          tooltip: 'Add photos',
          accent: true,
          onTap: () => _addPhotos(context, ref, ids),
        ),
        FTIconButton(
          icon: AppIcons.moreHoriz,
          tooltip: 'Album options',
          onTap: () async {
            final r = await showFTOptions<_AlbumAction>(
              context,
              title: a.name,
              options: const [
                FTOption(_AlbumAction.edit, 'Edit name & description', icon: AppIcons.edit),
                FTOption(_AlbumAction.delete, 'Delete album',
                    icon: AppIcons.trash, danger: true, subtitle: 'Photos stay in your gallery'),
              ],
            );
            if (r == null || !context.mounted) return;
            switch (r) {
              case _AlbumAction.edit:
                await _edit(context, ref, a);
              case _AlbumAction.delete:
                await _delete(context, ref, a, ids.length);
            }
          },
        ),
      ],
      body: LayoutBuilder(builder: (context, cons) {
        final cols = gridColumnsFor(cons.maxWidth - pad * 2);
        return CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, Gap.xs, pad, Gap.lg),
                child: ContentWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _AlbumHeader(
                        album: a,
                        cover: cover,
                        count: ids.length,
                        onEdit: () => _edit(context, ref, a),
                      ),
                      if (photos.isNotEmpty) ...[
                        const SizedBox(height: Gap.xs),
                        Text('Long-press a photo to make it the cover or remove it from the album.',
                            style: context.tx.caption),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (photos.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: AppIcons.photos,
                  title: 'This album is empty',
                  message: 'Add photos from your gallery or import new ones.',
                  actionLabel: 'Add photos',
                  onAction: () => _addPhotos(context, ref, ids),
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
                      final m = photos[i];
                      return FadeSlideIn(
                        index: i % (cols * 6),
                        offset: 10,
                        child: MediaThumb(
                          media: m,
                          badge: cover?.id == m.id && a.coverMediaId == m.id ? 'Cover' : null,
                          onTap: () => context.push(Routes.media(m.id), extra: ids),
                          onLongPress: () => showPhotoActions(context, ref, m, contextIds: ids, albumId: a.id),
                        ),
                      );
                    },
                    childCount: photos.length,
                  ),
                ),
              ),
          ],
        );
      }),
    );
  }
}

class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({required this.album, required this.cover, required this.count, required this.onEdit});
  final Album album;
  final MediaAsset? cover;
  final int count;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final c = context.ft;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final desc = album.description?.trim() ?? '';
    final countLabel = '$count ${count == 1 ? 'photo' : 'photos'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (cover != null)
          FTCard(
            padding: EdgeInsets.zero,
            semanticLabel: '${album.name}, $countLabel',
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: LayoutBuilder(builder: (context, cons) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.file(
                      File(cover!.isImage ? cover!.absolutePath : cover!.thumbAbsolutePath),
                      fit: BoxFit.cover,
                      cacheWidth: (cons.maxWidth * dpr).round().clamp(200, 2000),
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const MediaPlaceholder(icon: AppIcons.album),
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x00000000), Color(0x22000000), Color(0xB3000000)],
                          stops: [0, 0.5, 1],
                        ),
                      ),
                    ),
                    const Positioned(top: 12, right: 12, child: IconBadge(icon: AppIcons.album, size: 38)),
                    Positioned(
                      left: Gap.lg,
                      right: Gap.lg,
                      bottom: Gap.md,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(album.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.tx.headline.copyWith(color: Colors.white)),
                          const SizedBox(height: 2),
                          Text(countLabel, style: context.tx.caption.copyWith(color: Colors.white70)),
                        ],
                      ),
                    ),
                  ],
                );
              }),
            ),
          )
        else
          FTCard(
            child: Row(
              children: [
                const IconBadge(icon: AppIcons.album, size: 48),
                const SizedBox(width: Gap.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(album.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: context.tx.title),
                      const SizedBox(height: 2),
                      Text(countLabel, style: context.tx.caption),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: Gap.sm),
        if (desc.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(desc, style: context.tx.body.copyWith(color: c.text2)),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: FTTextAction('Add a description', accent: true, onTap: onEdit),
          ),
      ],
    );
  }
}

class _AlbumForm extends StatefulWidget {
  const _AlbumForm({required this.name, required this.description});
  final String name;
  final String description;

  @override
  State<_AlbumForm> createState() => _AlbumFormState();
}

class _AlbumFormState extends State<_AlbumForm> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name);
  late final _desc = TextEditingController(text: widget.description);

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop((_name.text.trim(), _desc.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FTTextField(
            controller: _name,
            label: 'Album name',
            icon: AppIcons.album,
            textInputAction: TextInputAction.next,
            validator: (v) => (v == null || v.trim().isEmpty) ? 'Please enter a name' : null,
          ),
          const SizedBox(height: Gap.sm),
          FTTextField(
            controller: _desc,
            label: 'Description',
            hint: 'What is this album about?',
            minLines: 2,
            maxLines: 5,
          ),
          const SizedBox(height: Gap.lg),
          FTButton(label: 'Save', expand: true, onTap: _save),
        ],
      ),
    );
  }
}
