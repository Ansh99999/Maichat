import 'studio_tools.dart';

/// Tools that reach past the draft for knowledge — the web, and the Studio's
/// memory across sessions. Registered into [kStudioTools] alongside the draft
/// tools.
final List<StudioTool> kKnowledgeTools = <StudioTool>[];

/// Which of [kKnowledgeTools] a sub-agent of a given type gets, by name. The
/// main agent gets them all.
const Map<String, List<String>> kKnowledgeToolsFor = <String, List<String>>{};
