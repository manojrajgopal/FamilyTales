import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../core/database/app_database.dart';
import '../../core/models/enums.dart';
import '../../core/repositories/content_repository.dart';
import '../../core/widgets/widgets.dart';
import 'event_logic.dart';

/// Confirms and moves an event to the trash, offering Undo. Returns true
/// when the event was trashed.
Future<bool> confirmTrashEvent(
    BuildContext context, WidgetRef ref, FamilyEvent event) async {
  final ok = await showFTConfirm(
    context,
    title: 'Move event to trash?',
    message: '“${event.title}” will be moved to the trash. Linked photos and '
        'stories are kept. You can restore it from Trash.',
    confirmLabel: 'Move to trash',
    destructive: true,
    icon: AppIcons.delete,
  );
  if (!ok || !context.mounted) return false;
  // Capture repositories now: the screen may be gone when Undo is tapped.
  final content = ref.read(contentRepoProvider);
  final system = ref.read(systemRepoProvider);
  try {
    await content.trashEvent(event.id);
  } catch (e) {
    if (context.mounted) showFTToast(context, friendlyError(e), error: true);
    return false;
  }
  if (context.mounted) {
    showFTToast(
      context,
      'Event moved to trash',
      actionLabel: 'Undo',
      onAction: () async {
        try {
          final records = await system.watchTrash().first;
          for (final r in records) {
            if (r.entityType == TrashEntity.event && r.entityId == event.id) {
              await system.restore(r.id);
              break;
            }
          }
        } catch (_) {
          // The record may already have been purged; nothing to undo.
        }
      },
    );
  }
  return true;
}

/// Makes [mediaIds] exactly the photos linked to [eventId], keeping every
/// photo's links to other events intact.
Future<void> setEventPhotos(WidgetRef ref, String eventId, Set<String> mediaIds) async {
  final repo = ref.read(contentRepoProvider);
  final links = await ref.read(mediaEventsProvider.future);
  final byMedia = <String, Set<String>>{};
  for (final l in links) {
    (byMedia[l.mediaId] ??= {}).add(l.eventId);
  }
  final before = {for (final l in links) if (l.eventId == eventId) l.mediaId};
  for (final m in mediaIds.difference(before)) {
    await repo.setMediaEvents(m, {...?byMedia[m], eventId});
  }
  for (final m in before.difference(mediaIds)) {
    await repo.setMediaEvents(m, {...?byMedia[m]}..remove(eventId));
  }
}

/// Shares a plain-text summary of the event through the system share sheet.
Future<void> shareEvent(
    BuildContext context, WidgetRef ref, EventWithPeople item) async {
  final graph = ref.read(familyGraphProvider).value;
  final box = context.findRenderObject() as RenderBox?;
  try {
    await SharePlus.instance.share(ShareParams(
      text: EventQuery.shareText(item, graph),
      subject: item.event.title,
      sharePositionOrigin:
          box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size,
    ));
  } catch (_) {
    if (context.mounted) {
      showFTToast(context, 'Sharing isn’t available on this device', error: true);
    }
  }
}
