import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../app/providers.dart';
import '../../core/models/enums.dart';
import '../../core/widgets/widgets.dart';

enum _Source { camera, library, files }

/// Shared "add photos" flow: asks Camera / Photo library / Files, copies the
/// chosen images into private app storage, links them to the given people,
/// events or album, and returns the new media ids.
Future<List<String>> importPhotosFlow(
  BuildContext context,
  WidgetRef ref, {
  List<String> personIds = const [],
  List<String> eventIds = const [],
  String? albumId,
  bool single = false,
  String title = 'Add photos',
}) async {
  final treeId = ref.read(activeTreeIdProvider);
  if (treeId == null) return const [];
  final src = await showFTOptions<_Source>(
    context,
    title: title,
    options: const [
      FTOption(_Source.camera, 'Take a photo', icon: AppIcons.camera, subtitle: 'Use the camera'),
      FTOption(_Source.library, 'Photo library', icon: AppIcons.photos, subtitle: 'Choose from your device'),
      FTOption(_Source.files, 'Files', icon: AppIcons.document, subtitle: 'Scans and image files'),
    ],
  );
  if (src == null) return const [];

  final files = <File>[];
  final names = <String>[];
  try {
    final picker = ImagePicker();
    switch (src) {
      case _Source.camera:
        final x = await picker.pickImage(source: ImageSource.camera, imageQuality: 92, maxWidth: 3200);
        if (x != null) {
          files.add(File(x.path));
          names.add(x.name);
        }
      case _Source.library:
        if (single) {
          final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 92, maxWidth: 3200);
          if (x != null) {
            files.add(File(x.path));
            names.add(x.name);
          }
        } else {
          final xs = await picker.pickMultiImage(imageQuality: 92, maxWidth: 3200);
          for (final x in xs) {
            files.add(File(x.path));
            names.add(x.name);
          }
        }
      case _Source.files:
        final res = await FilePicker.pickFiles(type: FileType.image);
        for (final f in res) {
          if (f.path != null) {
            files.add(File(f.path!));
            names.add(f.name);
          }
          if (single) break;
        }
    }
  } catch (e) {
    if (context.mounted) {
      showFTToast(context, 'Could not open ${src == _Source.camera ? 'the camera' : 'your photos'}. '
          'Check the app’s permissions in system settings.', error: true);
    }
    return const [];
  }
  if (files.isEmpty) return const [];

  final repo = ref.read(contentRepoProvider);
  final ids = <String>[];
  for (var i = 0; i < files.length; i++) {
    try {
      ids.add(await repo.importMedia(
        files[i],
        treeId: treeId,
        kind: MediaKind.photo,
        personIds: personIds,
        eventIds: eventIds,
        albumId: albumId,
        originalName: names[i],
      ));
    } catch (e) {
      if (context.mounted) showFTToast(context, 'Could not import ${names[i]}', error: true);
    }
  }
  if (context.mounted && ids.isNotEmpty && !single) {
    showFTToast(context, ids.length == 1 ? 'Photo added' : '${ids.length} photos added');
  }
  return ids;
}
