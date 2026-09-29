import 'studio_tools.dart';

/// Tools about the run itself rather than the draft — messaging and waiting on
/// sub-agents. Registered into [kStudioTools] alongside the draft tools.
final List<StudioTool> kRuntimeTools = <StudioTool>[];

/// Which of [kRuntimeTools] a sub-agent of a given type gets, by name. The main
/// agent gets them all.
const Map<String, List<String>> kRuntimeToolsFor = <String, List<String>>{};
