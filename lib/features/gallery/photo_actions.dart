import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/widgets/widgets.dart';
import '../family/domain/family_graph.dart';
import '../members/widgets/person_widgets.dart';
import 'media_tools.dart';

/// Shared user flows for photos and albums (used by the gallery, album,
/// viewer and editor screens). Each flow handles its own confirmation and
/// feedback toast.

/// Asks for a name and creates an album. Returns the new album id.
Future<String?> createAlbumFlow(BuildContext context, WidgetRef ref, {String? name}) async {
  final treeId = ref.read(activeTreeIdProvider);
  if (treeId == null) return null;
  final repo = ref.read(contentRepoProvider);
  final chosen = name ??
      await showFTTextPrompt(
        context,
        title: 'New album',
        label: 'Album name',
        hint: 'e.g. Summer at the lake',
        confirmLabel: 'Create album',
      );
  if (chosen == null || chosen.trim().isEmpty) return null;
  try {
    final id = await repo.createAlbum(treeId, chosen);
    if (context.mounted) showFTToast(context, 'Album “${chosen.trim()}” created');
    return id;
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    return null;
  }
}

/// Lets the user choose an album (or create one) and adds [mediaIds] to it.
Future<void> addToAlbumFlow(BuildContext context, WidgetRef ref, List<String> mediaIds) async {
  if (mediaIds.isEmpty) return;
  final repo = ref.read(contentRepoProvider);
  final albums = ref.read(albumsProvider).value ?? const <Album>[];
  final entries = ref.read(albumEntriesProvider).value ?? const <AlbumMediaEntry>[];
  final containing = {
    for (final e in entries)
      if (mediaIds.length == 1 && e.mediaId == mediaIds.first) e.albumId,
  };
  const newAlbum = '\u0000new';
  final choice = await showFTOptions<String>(
    context,
    title: 'Add to album',
    options: [
      const FTOption(newAlbum, 'New album…', icon: AppIcons.add, subtitle: 'Create an album and add to it'),
      for (final a in albums)
        FTOption(a.id, a.name,
            icon: AppIcons.album,
            selected: containing.contains(a.id),
            subtitle: containing.contains(a.id) ? 'Already in this album' : null),
    ],
  );
  if (choice == null || !context.mounted) return;
  String? albumId = choice;
  if (choice == newAlbum) {
    albumId = await createAlbumFlow(context, ref);
    if (albumId == null) return;
  }
  try {
    await repo.addToAlbum(albumId, mediaIds);
    final name = albums.where((a) => a.id == albumId).map((a) => a.name).firstOrNull;
    if (context.mounted) {
      showFTToast(
          context,
          mediaIds.length == 1
              ? 'Added to ${name ?? 'album'}'
              : '${mediaIds.length} photos added to ${name ?? 'album'}');
    }
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
  }
}

/// Confirms and moves a photo / document to the trash with an Undo toast.
/// Tagged people are never affected.
Future<bool> trashMediaFlow(BuildContext context, WidgetRef ref, MediaAsset media) async {
  final isPhoto = media.kind == MediaKind.photo;
  final ok = await showFTConfirm(
    context,
    title: isPhoto ? 'Move photo to trash?' : 'Move document to trash?',
    message: isPhoto
        ? 'You can restore it from the trash. People tagged in this photo are not affected and keep their other photos.'
        : 'You can restore it from the trash. Sources that point to it will show it again once restored.',
    confirmLabel: 'Move to trash',
    destructive: true,
    icon: AppIcons.trash,
  );
  if (!ok || !context.mounted) return false;
  final repo = ref.read(contentRepoProvider);
  return trashWithUndo(
    context,
    ref,
    type: TrashEntity.media,
    id: media.id,
    trash: () => repo.trashMedia(media.id),
    message: isPhoto ? 'Photo moved to trash' : 'Document moved to trash',
  );
}

/// Sets [media] as the profile photo of a person tagged in it (or of anyone
/// the user picks, who is then tagged as well).
Future<void> setProfilePhotoFlow(BuildContext context, WidgetRef ref, MediaAsset media) async {
  final graph = ref.read(familyGraphProvider).value ?? FamilyGraph.empty();
  final tagged = [
    for (final r in ref.read(mediaPeopleProvider).value ?? const <MediaPerson>[])
      if (r.mediaId == media.id && graph[r.personId] != null) graph[r.personId]!,
  ];
  const other = '\u0000other';
  String? personId;
  if (tagged.isEmpty) {
    personId = await pickPerson(context, title: 'Profile photo for…');
  } else {
    personId = await showFTOptions<String>(
      context,
      title: 'Use as profile photo for',
      options: [
        for (final p in tagged)
          FTOption(p.id, p.displayName,
              icon: AppIcons.person,
              selected: p.profileMediaId == media.id,
              subtitle: p.profileMediaId == media.id ? 'Current profile photo' : null),
        const FTOption(other, 'Someone else…', icon: AppIcons.people),
      ],
    );
    if (personId == other && context.mounted) {
      personId = await pickPerson(context, title: 'Profile photo for…', exclude: {for (final p in tagged) p.id});
    }
  }
  if (personId == null || !context.mounted) return;
  final family = ref.read(familyRepoProvider);
  final content = ref.read(contentRepoProvider);
  try {
    await family.setProfilePhoto(personId, media.id);
    // Add the tag without rewriting the others (people in the trash keep theirs).
    if (!tagged.any((p) => p.id == personId)) await content.addMediaPerson(media.id, personId);
    final name = graph[personId]?.displayName ?? 'this person';
    if (context.mounted) showFTToast(context, 'Profile photo updated for $name');
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
  }
}

enum _PhotoAction { open, edit, album, share, profile, trash, cover, remove }

/// Long-press menu for a photo tile. [albumId] adds album-specific actions.
Future<void> showPhotoActions(
  BuildContext context,
  WidgetRef ref,
  MediaAsset media, {
  List<String>? contextIds,
  String? albumId,
}) async {
  final action = await showFTOptions<_PhotoAction>(
    context,
    title: media.displayTitle,
    options: [
      const FTOption(_PhotoAction.open, 'View', icon: AppIcons.eye),
      const FTOption(_PhotoAction.edit, 'Edit details', icon: AppIcons.edit, subtitle: 'Caption, date, people, crop'),
      if (albumId != null) ...[
        const FTOption(_PhotoAction.cover, 'Set as album cover', icon: AppIcons.photo),
        const FTOption(_PhotoAction.remove, 'Remove from album',
            icon: AppIcons.remove, subtitle: 'The photo stays in your gallery'),
      ] else
        const FTOption(_PhotoAction.album, 'Add to album', icon: AppIcons.album),
      const FTOption(_PhotoAction.profile, 'Use as profile photo', icon: AppIcons.person),
      const FTOption(_PhotoAction.share, 'Share', icon: AppIcons.share),
      const FTOption(_PhotoAction.trash, 'Move to trash', icon: AppIcons.trash, danger: true),
    ],
  );
  if (action == null || !context.mounted) return;
  final repo = ref.read(contentRepoProvider);
  switch (action) {
    case _PhotoAction.open:
      context.push(Routes.media(media.id), extra: contextIds);
    case _PhotoAction.edit:
      context.push(Routes.mediaEdit(media.id));
    case _PhotoAction.album:
      await addToAlbumFlow(context, ref, [media.id]);
    case _PhotoAction.share:
      await shareMediaFile(context, media);
    case _PhotoAction.profile:
      await setProfilePhotoFlow(context, ref, media);
    case _PhotoAction.trash:
      await trashMediaFlow(context, ref, media);
    case _PhotoAction.cover:
      await repo.updateAlbum(albumId!, coverMediaId: media.id);
      if (context.mounted) showFTToast(context, 'Album cover updated');
    case _PhotoAction.remove:
      final id = albumId!;
      await repo.removeFromAlbum(id, media.id);
      if (context.mounted) {
        showFTToast(context, 'Removed from album',
            actionLabel: 'Undo', onAction: () => repo.addToAlbum(id, [media.id]));
      }
  }
}
