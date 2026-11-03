import 'dart:io';

import 'package:drift/drift.dart' hide Column, Table;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/models/fuzzy_date.dart';
import '../../core/services/app_paths.dart';
import '../../core/services/media_storage.dart';
import '../../core/widgets/widgets.dart';

/// Default photo categories. The category column is free text, so users can
/// also type their own; these are offered as quick choices.
const kPhotoCategories = <String>[
  'Childhood',
  'Weddings',
  'Family Functions',
  'Grandparents',
  'Parents',
  'Family Trips',
  'Historical Photos',
  'Memories',
];

/// Album names suggested when the user has not created them yet.
const kSuggestedAlbums = kPhotoCategories;

/// Display helpers for the generated [MediaAsset] data class.
extension MediaAssetX on MediaAsset {
  /// Whether the file can be shown as an image (photos and image scans).
  bool get isImage =>
      kind == MediaKind.photo || MediaStorage.isImagePath(filePath);

  bool get isPdf =>
      mimeType == 'application/pdf' || filePath.toLowerCase().endsWith('.pdf');

  String get displayTitle {
    final c = caption?.trim();
    if (c != null && c.isNotEmpty) return c;
    final o = originalName?.trim();
    if (o != null && o.isNotEmpty) return o;
    return kind == MediaKind.photo ? 'Photo' : 'Document';
  }

  String get absolutePath => AppPaths.I.resolve(filePath);

  /// Thumbnail when available, otherwise the original file.
  String get thumbAbsolutePath => AppPaths.I.resolve(thumbPath ?? filePath);

  FuzzyDate? get fuzzyDate => FuzzyDate.tryParse(date);

  IconData get kindIcon =>
      isImage ? AppIcons.photo : (isPdf ? AppIcons.pdf : AppIcons.document);
}

/// Grid column count derived from the available width (never hard-coded).
int gridColumnsFor(double width, {double target = 112, int min = 3, int max = 10}) =>
    (width / target).floor().clamp(min, max);

/// Totals shown in the gallery storage line.
class MediaStats {
  const MediaStats({required this.photos, required this.documents, required this.bytes});

  factory MediaStats.of(Iterable<MediaAsset> media) {
    var photos = 0, docs = 0, bytes = 0;
    for (final m in media) {
      if (m.kind == MediaKind.photo) {
        photos++;
      } else {
        docs++;
      }
      bytes += m.sizeBytes;
    }
    return MediaStats(photos: photos, documents: docs, bytes: bytes);
  }

  final int photos;
  final int documents;
  final int bytes;

  String get label {
    final parts = <String>[
      '$photos ${photos == 1 ? 'photo' : 'photos'}',
      '$documents ${documents == 1 ? 'document' : 'documents'}',
    ];
    return '${parts.join(' · ')} · ${formatBytes(bytes)}';
  }
}

/// Filtering of the photo grid by tagged person and category.
class PhotoFilter {
  const PhotoFilter({this.personId, this.category});
  final String? personId;
  final String? category;

  bool get isActive => personId != null || category != null;

  List<MediaAsset> apply(List<MediaAsset> photos, Map<String, Set<String>> peopleByMedia) {
    final cat = category?.toLowerCase();
    return [
      for (final m in photos)
        if ((personId == null || (peopleByMedia[m.id]?.contains(personId) ?? false)) &&
            (cat == null || (m.category?.trim().toLowerCase() ?? '') == cat))
          m,
    ];
  }
}

/// Category choices: defaults first, then any custom categories in use.
List<String> categoryChoices(Iterable<MediaAsset> media) {
  final out = <String>[...kPhotoCategories];
  final seen = {for (final c in out) c.toLowerCase()};
  final custom = <String>{};
  for (final m in media) {
    final c = m.category?.trim();
    if (c == null || c.isEmpty) continue;
    if (!seen.contains(c.toLowerCase())) custom.add(c);
  }
  final sorted = custom.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [...out, ...sorted];
}

/// Groups `media_persons` rows by media id.
Map<String, Set<String>> peopleByMedia(Iterable<MediaPerson> rows) {
  final out = <String, Set<String>>{};
  for (final r in rows) {
    (out[r.mediaId] ??= <String>{}).add(r.personId);
  }
  return out;
}

/// Groups `media_events` rows by media id.
Map<String, Set<String>> eventsByMedia(Iterable<MediaEvent> rows) {
  final out = <String, Set<String>>{};
  for (final r in rows) {
    (out[r.mediaId] ??= <String>{}).add(r.eventId);
  }
  return out;
}

/// Media ids of an album, in album order.
List<String> albumMediaIds(String albumId, Iterable<AlbumMediaEntry> entries, Map<String, MediaAsset> byId) {
  final list = [
    for (final e in entries)
      if (e.albumId == albumId && byId.containsKey(e.mediaId)) e,
  ]..sort((a, b) {
      final s = a.sortOrder.compareTo(b.sortOrder);
      return s != 0 ? s : a.addedAt.compareTo(b.addedAt);
    });
  return [for (final e in list) e.mediaId];
}

/// The cover of an album: its explicit cover (if still present) or the first
/// photo.
MediaAsset? albumCover(Album album, List<String> ids, Map<String, MediaAsset> byId) {
  final explicit = album.coverMediaId == null ? null : byId[album.coverMediaId];
  if (explicit != null && explicit.isImage) return explicit;
  for (final id in ids) {
    final m = byId[id];
    if (m != null && m.isImage) return m;
  }
  return null;
}

// ================================================================== trash

/// Finds the newest trash record for an entity so the deletion can be
/// undone with [SystemRepository.restore].
Future<String?> findTrashRecordId(AppDatabase db, TrashEntity type, String entityId) async {
  final rec = await (db.select(db.deletionRecords)
        ..where((d) => d.entityId.equals(entityId) & d.entityType.equalsValue(type))
        ..orderBy([(d) => OrderingTerm.desc(d.deletedAt)])
        ..limit(1))
      .getSingleOrNull();
  return rec?.id;
}

/// Runs [trash], then shows a toast with an Undo action that restores the
/// record. Call it while [context] is still mounted (before popping).
Future<bool> trashWithUndo(
  BuildContext context,
  WidgetRef ref, {
  required TrashEntity type,
  required String id,
  required Future<void> Function() trash,
  required String message,
}) async {
  final db = ref.read(databaseProvider);
  final system = ref.read(systemRepoProvider);
  try {
    await trash();
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    return false;
  }
  final recordId = await findTrashRecordId(db, type, id);
  if (!context.mounted) return true;
  showFTToast(
    context,
    message,
    actionLabel: recordId == null ? null : 'Undo',
    onAction: recordId == null
        ? null
        : () {
            system.restore(recordId).catchError((_) => false);
          },
  );
  return true;
}

// ================================================================== files

/// Opens the system share sheet for a stored file ("open with…" lives there
/// too, since the app never uploads anything itself).
Future<void> shareMediaFile(BuildContext context, MediaAsset media) async {
  final path = media.absolutePath;
  final box = context.findRenderObject() as RenderBox?;
  final origin = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
  try {
    if (!await File(path).exists()) {
      if (context.mounted) showFTToast(context, 'The file is missing from this device.', error: true);
      return;
    }
    await SharePlus.instance.share(ShareParams(
      files: [XFile(path, mimeType: media.mimeType, name: media.originalName)],
      subject: media.caption,
      sharePositionOrigin: origin,
    ));
  } catch (e) {
    if (context.mounted) showFTToast(context, 'Could not share this file.', error: true);
  }
}

/// Lets the user pick files (any type) and imports them into private app
/// storage. Images picked here are stored as photos unless [kind] is given.
Future<List<String>> importFilesFlow(
  BuildContext context,
  WidgetRef ref, {
  MediaKind? kind = MediaKind.document,
  bool single = false,
  String dialogTitle = 'Choose documents',
}) async {
  final treeId = ref.read(activeTreeIdProvider);
  if (treeId == null) return const [];
  final repo = ref.read(contentRepoProvider);
  List<PlatformFile> picked;
  try {
    picked = await FilePicker.pickFiles(dialogTitle: dialogTitle);
  } catch (_) {
    if (context.mounted) {
      showFTToast(context, 'Could not open your files. Check the app’s permissions in system settings.',
          error: true);
    }
    return const [];
  }
  if (single && picked.length > 1) picked = [picked.first];
  final ids = <String>[];
  for (final f in picked) {
    File? temp;
    try {
      File src;
      final path = f.path;
      if (path != null) {
        src = File(path);
      } else {
        temp = File(p.join(AppPaths.I.temp.path, '${DateTime.now().microsecondsSinceEpoch}_${f.name}'));
        await temp.writeAsBytes(await f.readAsBytes(), flush: true);
        src = temp;
      }
      ids.add(await repo.importMedia(src, treeId: treeId, kind: kind, originalName: f.name));
    } catch (_) {
      if (context.mounted) showFTToast(context, 'Could not import ${f.name}', error: true);
    } finally {
      if (temp != null) {
        try {
          await temp.delete();
        } catch (_) {}
      }
    }
  }
  if (context.mounted && ids.isNotEmpty && !single) {
    showFTToast(context, ids.length == 1 ? 'File added' : '${ids.length} files added');
  }
  return ids;
}

/// Clears decoded images so an edited file (rotate / crop) is re-read.
void evictImageCache() {
  PaintingBinding.instance.imageCache.clear();
  PaintingBinding.instance.imageCache.clearLiveImages();
}
