import '../../models/discover.dart';
import 'botbooru_source.dart';
import 'character_tavern_source.dart';
import 'chub_source.dart';
import 'datacat_source.dart';
import 'discover_source.dart';
import 'janny_source.dart';
import 'pygmalion_source.dart';
import 'risu_realm_source.dart';
import 'wyvern_source.dart';

export 'botbooru_source.dart';
export 'browser_clearance.dart';
export 'character_tavern_source.dart';
export 'chub_source.dart';
export 'datacat_source.dart';
export 'discover_source.dart';
export 'janny_source.dart';
export 'pygmalion_source.dart';
export 'risu_realm_source.dart';
export 'sveltekit_data.dart';
export 'wyvern_source.dart';

/// The catalogues Discover can browse, in the order their chips appear.
///
/// Add a [DiscoverSource] here and it shows up everywhere: the source chips, the
/// per-section sort menus, the filter sheet. Sources are built lazily and live
/// for as long as the Discover screen does.
List<DiscoverSource> buildDiscoverSources() => <DiscoverSource>[
      ChubSource(),
      CharacterTavernSource(),
      RisuRealmSource(),
      WyvernSource(),
      BotbooruSource(),
      DataCatSource(),
      PygmalionSource(),
      JannySource(),
    ];

/// The sources that publish [kind], so a section can say who it is asking.
List<DiscoverSource> sourcesFor(
  List<DiscoverSource> sources,
  DiscoverKind kind,
) =>
    sources.where((s) => s.supports(kind)).toList(growable: false);
