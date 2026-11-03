import 'package:flutter/widgets.dart';

import '../models/enums.dart';

/// Semantic icon set. Glyphs come from the Phosphor icon fonts (MIT),
/// bundled as app assets – no network, no third-party runtime code. Screens should
/// use these names so the visual language stays consistent.
abstract final class AppIcons {
  // Navigation
  static const IconData home = IconData(0xe2c6, fontFamily: 'PhosphorRegular');
  static const IconData homeActive = IconData(0xe2c6, fontFamily: 'PhosphorFill');
  static const IconData tree = IconData(0xe67c, fontFamily: 'PhosphorRegular');
  static const IconData treeActive = IconData(0xe67c, fontFamily: 'PhosphorFill');
  static const IconData members = IconData(0xe68e, fontFamily: 'PhosphorRegular');
  static const IconData membersActive = IconData(0xe68e, fontFamily: 'PhosphorFill');
  static const IconData timeline = IconData(0xe1a0, fontFamily: 'PhosphorRegular');
  static const IconData timelineActive = IconData(0xe1a0, fontFamily: 'PhosphorFill');
  static const IconData more = IconData(0xe464, fontFamily: 'PhosphorRegular');
  static const IconData moreActive = IconData(0xe464, fontFamily: 'PhosphorFill');

  // Actions
  static const IconData back = IconData(0xe138, fontFamily: 'PhosphorRegular');
  static const IconData forward = IconData(0xe13a, fontFamily: 'PhosphorRegular');
  static const IconData chevronDown = IconData(0xe136, fontFamily: 'PhosphorRegular');
  static const IconData arrowUpRight = IconData(0xe092, fontFamily: 'PhosphorRegular');
  static const IconData arrowRight = IconData(0xe06c, fontFamily: 'PhosphorRegular');
  static const IconData arrowUp = IconData(0xe08e, fontFamily: 'PhosphorRegular');
  static const IconData arrowDown = IconData(0xe03e, fontFamily: 'PhosphorRegular');
  static const IconData arrowsLeftRight = IconData(0xe0a0, fontFamily: 'PhosphorRegular');
  static const IconData add = IconData(0xe3d4, fontFamily: 'PhosphorRegular');
  static const IconData remove = IconData(0xe32a, fontFamily: 'PhosphorRegular');
  static const IconData close = IconData(0xe4f6, fontFamily: 'PhosphorRegular');
  static const IconData check = IconData(0xe182, fontFamily: 'PhosphorRegular');
  static const IconData checkCircle = IconData(0xe184, fontFamily: 'PhosphorFill');
  static const IconData edit = IconData(0xe3b4, fontFamily: 'PhosphorRegular');
  static const IconData delete = IconData(0xe4a8, fontFamily: 'PhosphorRegular');
  static const IconData share = IconData(0xe408, fontFamily: 'PhosphorRegular');
  static const IconData export = IconData(0xeaf0, fontFamily: 'PhosphorRegular');
  static const IconData download = IconData(0xe20c, fontFamily: 'PhosphorRegular');
  static const IconData upload = IconData(0xe4c0, fontFamily: 'PhosphorRegular');
  static const IconData search = IconData(0xe30c, fontFamily: 'PhosphorRegular');
  static const IconData filter = IconData(0xe266, fontFamily: 'PhosphorRegular');
  static const IconData sliders = IconData(0xe434, fontFamily: 'PhosphorRegular');
  static const IconData sort = IconData(0xe444, fontFamily: 'PhosphorRegular');
  static const IconData moreHoriz = IconData(0xe1fe, fontFamily: 'PhosphorRegular');
  static const IconData moreVert = IconData(0xe208, fontFamily: 'PhosphorRegular');
  static const IconData copy = IconData(0xe1ca, fontFamily: 'PhosphorRegular');
  static const IconData undo = IconData(0xe038, fontFamily: 'PhosphorRegular');
  static const IconData refresh = IconData(0xe094, fontFamily: 'PhosphorRegular');
  static const IconData rotate = IconData(0xe036, fontFamily: 'PhosphorRegular');
  static const IconData crop = IconData(0xe1d4, fontFamily: 'PhosphorRegular');
  static const IconData link = IconData(0xe2e6, fontFamily: 'PhosphorRegular');
  static const IconData merge = IconData(0xe280, fontFamily: 'PhosphorRegular');
  static const IconData branch = IconData(0xe278, fontFamily: 'PhosphorRegular');
  static const IconData path = IconData(0xe39c, fontFamily: 'PhosphorRegular');
  static const IconData swap = IconData(0xe83c, fontFamily: 'PhosphorRegular');
  static const IconData info = IconData(0xe2ce, fontFamily: 'PhosphorRegular');
  static const IconData warning = IconData(0xe4e2, fontFamily: 'PhosphorRegular');
  static const IconData eye = IconData(0xe220, fontFamily: 'PhosphorRegular');
  static const IconData eyeOff = IconData(0xe224, fontFamily: 'PhosphorRegular');
  static const IconData selectAll = IconData(0xe746, fontFamily: 'PhosphorRegular');
  static const IconData checkSquare = IconData(0xe186, fontFamily: 'PhosphorRegular');

  // Tree controls
  static const IconData zoomIn = IconData(0xe3d4, fontFamily: 'PhosphorRegular');
  static const IconData zoomOut = IconData(0xe32a, fontFamily: 'PhosphorRegular');
  static const IconData fit = IconData(0xe1d0, fontFamily: 'PhosphorRegular');
  static const IconData center = IconData(0xe1d6, fontFamily: 'PhosphorRegular');
  static const IconData layout = IconData(0xee48, fontFamily: 'PhosphorRegular');
  static const IconData focus = IconData(0xe6fc, fontFamily: 'PhosphorRegular');
  static const IconData generations = IconData(0xe466, fontFamily: 'PhosphorRegular');
  static const IconData collapse = IconData(0xe09a, fontFamily: 'PhosphorRegular');
  static const IconData expand = IconData(0xe0a2, fontFamily: 'PhosphorRegular');

  // Domain
  static const IconData person = IconData(0xe4c2, fontFamily: 'PhosphorRegular');
  static const IconData personAdd = IconData(0xe4d0, fontFamily: 'PhosphorRegular');
  static const IconData people = IconData(0xe4d6, fontFamily: 'PhosphorRegular');
  static const IconData family = IconData(0xe68c, fontFamily: 'PhosphorRegular');
  static const IconData heart = IconData(0xe2a8, fontFamily: 'PhosphorRegular');
  static const IconData heartFill = IconData(0xe2a8, fontFamily: 'PhosphorFill');
  static const IconData baby = IconData(0xe774, fontFamily: 'PhosphorRegular');
  static const IconData calendar = IconData(0xe7b4, fontFamily: 'PhosphorRegular');
  static const IconData calendarBlank = IconData(0xe10a, fontFamily: 'PhosphorRegular');
  static const IconData bell = IconData(0xe0ce, fontFamily: 'PhosphorRegular');
  static const IconData bellRinging = IconData(0xe5e8, fontFamily: 'PhosphorRegular');
  static const IconData event = IconData(0xe622, fontFamily: 'PhosphorRegular');
  static const IconData photo = IconData(0xe2ca, fontFamily: 'PhosphorRegular');
  static const IconData photos = IconData(0xe836, fontFamily: 'PhosphorRegular');
  static const IconData camera = IconData(0xe10e, fontFamily: 'PhosphorRegular');
  static const IconData album = IconData(0xe25a, fontFamily: 'PhosphorRegular');
  static const IconData story = IconData(0xe8f2, fontFamily: 'PhosphorRegular');
  static const IconData storyAlt = IconData(0xe9c0, fontFamily: 'PhosphorRegular');
  static const IconData source = IconData(0xe606, fontFamily: 'PhosphorRegular');
  static const IconData document = IconData(0xe23a, fontFamily: 'PhosphorRegular');
  static const IconData pdf = IconData(0xe702, fontFamily: 'PhosphorRegular');
  static const IconData archive = IconData(0xe00c, fontFamily: 'PhosphorRegular');
  static const IconData backup = IconData(0xe1ae, fontFamily: 'PhosphorRegular');
  static const IconData restore = IconData(0xe1a0, fontFamily: 'PhosphorRegular');
  static const IconData database = IconData(0xe1de, fontFamily: 'PhosphorRegular');
  static const IconData storage = IconData(0xe2a0, fontFamily: 'PhosphorRegular');
  static const IconData trash = IconData(0xe4a6, fontFamily: 'PhosphorRegular');
  static const IconData settings = IconData(0xe272, fontFamily: 'PhosphorRegular');
  static const IconData shield = IconData(0xe40c, fontFamily: 'PhosphorRegular');
  static const IconData lock = IconData(0xe308, fontFamily: 'PhosphorRegular');
  static const IconData fingerprint = IconData(0xe23e, fontFamily: 'PhosphorRegular');
  static const IconData key = IconData(0xe2d6, fontFamily: 'PhosphorRegular');
  static const IconData palette = IconData(0xe6c8, fontFamily: 'PhosphorRegular');
  static const IconData textSize = IconData(0xe6ee, fontFamily: 'PhosphorRegular');
  static const IconData sun = IconData(0xe472, fontFamily: 'PhosphorRegular');
  static const IconData moon = IconData(0xe330, fontFamily: 'PhosphorRegular');
  static const IconData stats = IconData(0xe150, fontFamily: 'PhosphorRegular');
  static const IconData pie = IconData(0xe15a, fontFamily: 'PhosphorRegular');
  static const IconData location = IconData(0xe316, fontFamily: 'PhosphorRegular');
  static const IconData globe = IconData(0xe28c, fontFamily: 'PhosphorRegular');
  static const IconData tag = IconData(0xe478, fontFamily: 'PhosphorRegular');
  static const IconData note = IconData(0xe34e, fontFamily: 'PhosphorRegular');
  static const IconData lightning = IconData(0xe2de, fontFamily: 'PhosphorRegular');
  static const IconData sparkle = IconData(0xe6a2, fontFamily: 'PhosphorRegular');
  static const IconData cake = IconData(0xe780, fontFamily: 'PhosphorRegular');
  static const IconData flower = IconData(0xe6cc, fontFamily: 'PhosphorRegular');
  static const IconData leaf = IconData(0xe2da, fontFamily: 'PhosphorRegular');
  static const IconData candle = IconData(0xe624, fontFamily: 'PhosphorRegular');
  static const IconData clock = IconData(0xe19a, fontFamily: 'PhosphorRegular');
  static const IconData id = IconData(0xe2c8, fontFamily: 'PhosphorRegular');
  static const IconData quote = IconData(0xe660, fontFamily: 'PhosphorRegular');
  static const IconData bold = IconData(0xe5be, fontFamily: 'PhosphorRegular');
  static const IconData italic = IconData(0xe5c0, fontFamily: 'PhosphorRegular');
  static const IconData heading = IconData(0xe6ba, fontFamily: 'PhosphorRegular');
  static const IconData bullets = IconData(0xe2f2, fontFamily: 'PhosphorRegular');
  static const IconData mail = IconData(0xe218, fontFamily: 'PhosphorRegular');
  static const IconData phone = IconData(0xe3b8, fontFamily: 'PhosphorRegular');
  static const IconData language = IconData(0xe4a2, fontFamily: 'PhosphorRegular');
  static const IconData briefcase = IconData(0xe0ee, fontFamily: 'PhosphorRegular');
  static const IconData graduation = IconData(0xe62c, fontFamily: 'PhosphorRegular');
  static const IconData medal = IconData(0xe320, fontFamily: 'PhosphorRegular');
  static const IconData trophy = IconData(0xe67e, fontFamily: 'PhosphorRegular');
  static const IconData airplane = IconData(0xe504, fontFamily: 'PhosphorRegular');
  static const IconData house = IconData(0xe2c4, fontFamily: 'PhosphorRegular');
  static const IconData church = IconData(0xecea, fontFamily: 'PhosphorRegular');
  static const IconData scroll = IconData(0xeb7a, fontFamily: 'PhosphorRegular');
  static const IconData certificate = IconData(0xe766, fontFamily: 'PhosphorRegular');
  static const IconData microphone = IconData(0xe326, fontFamily: 'PhosphorRegular');
  static const IconData envelope = IconData(0xe214, fontFamily: 'PhosphorRegular');
  static const IconData book = IconData(0xe0e6, fontFamily: 'PhosphorRegular');
  static const IconData male = IconData(0xe6e2, fontFamily: 'PhosphorRegular');
  static const IconData female = IconData(0xe6e0, fontFamily: 'PhosphorRegular');
  static const IconData neutral = IconData(0xe6ea, fontFamily: 'PhosphorRegular');
  static const IconData duplicate = IconData(0xe1ca, fontFamily: 'PhosphorRegular');
  static const IconData fields = IconData(0xe5a2, fontFamily: 'PhosphorRegular');
  static const IconData broom = IconData(0xec54, fontFamily: 'PhosphorRegular');
  static const IconData zip = IconData(0xe958, fontFamily: 'PhosphorRegular');
  static const IconData handHeart = IconData(0xe810, fontFamily: 'PhosphorRegular');
  static const IconData footprints = IconData(0xea88, fontFamily: 'PhosphorRegular');
  static const IconData signpost = IconData(0xe89c, fontFamily: 'PhosphorRegular');
  static const IconData scales = IconData(0xe750, fontFamily: 'PhosphorRegular');
  static const IconData hourglass = IconData(0xe2b2, fontFamily: 'PhosphorRegular');
  static const IconData backspace = IconData(0xe0ae, fontFamily: 'PhosphorRegular');
  static const IconData plant = IconData(0xebae, fontFamily: 'PhosphorRegular');
  static const IconData star = IconData(0xe46a, fontFamily: 'PhosphorRegular');
  static const IconData confetti = IconData(0xe81a, fontFamily: 'PhosphorRegular');
  static const IconData globeSimple = IconData(0xe288, fontFamily: 'PhosphorRegular');

  static IconData forEvent(EventType t) => switch (t) {
        EventType.birth => baby,
        EventType.baptism => church,
        EventType.namingCeremony => sparkle,
        EventType.adoption => handHeart,
        EventType.engagement => heart,
        EventType.marriage => heartFill,
        EventType.divorce => arrowsLeftRight,
        EventType.separation => signpost,
        EventType.graduation => graduation,
        EventType.employment => briefcase,
        EventType.retirement => leaf,
        EventType.migration => airplane,
        EventType.relocation => house,
        EventType.militaryService => medal,
        EventType.award => trophy,
        EventType.achievement => star,
        EventType.death => flower,
        EventType.burial => plant,
        EventType.memorial => candle,
        EventType.familyReunion => family,
        EventType.custom => event,
      };

  static IconData forSource(SourceType t) => switch (t) {
        SourceType.certificate => certificate,
        SourceType.photograph => photo,
        SourceType.letter => envelope,
        SourceType.document => document,
        SourceType.familyRecord => book,
        SourceType.oralHistory => microphone,
        SourceType.census => scroll,
        SourceType.book => book,
        SourceType.other => source,
      };

  static IconData forGender(Gender g) => switch (g) {
        Gender.male => male,
        Gender.female => female,
        _ => neutral,
      };
}
