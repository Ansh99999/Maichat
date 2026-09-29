import '../../models/studio.dart';
import 'studio_memory.dart';
import 'studio_web.dart';

/// What the knowledge tools reach: the Studio's settings as they are now, the
/// web, and the memory. Held by [StudioToolContext.knowledge].
///
/// One instance serves the whole app — [shared] — set up once there is an
/// [AppState] to read the settings from (`StudioKnowledge.configure`). Until
/// then the tools still run on the defaults: web research on Wikipedia and
/// Fandom, and no memory, which the memory tools say plainly.
class StudioKnowledge {
  StudioKnowledge({
    StudioConfig Function()? config,
    StudioWeb? web,
    this.memory,
  })  : config = config ?? (() => const StudioConfig()),
        web = web ?? StudioWeb();

  /// The Studio's settings, read fresh on every call so a change in settings
  /// reaches a run already going.
  final StudioConfig Function() config;
  final StudioWeb web;
  StudioMemory? memory;

  static StudioKnowledge shared = StudioKnowledge();

  /// Points [shared] at the app's settings and, once it has been read, its
  /// memory. Safe to call again: the web client and memory already loaded
  /// are kept unless new ones are given.
  static void configure({
    required StudioConfig Function() config,
    StudioMemory? memory,
  }) {
    shared = StudioKnowledge(
      config: config,
      web: shared.web,
      memory: memory ?? shared.memory,
    );
  }

  /// The memory, when it is switched on and has been read.
  StudioMemory? get activeMemory =>
      config().memoryEnabled ? memory : null;
}
