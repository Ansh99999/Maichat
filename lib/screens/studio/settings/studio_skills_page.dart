import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/studio_skill.dart';
import '../../../services/studio/studio_skills.dart';
import '../../../services/studio/studio_store.dart';
import '../../../widgets/message_markdown.dart';
import '../studio_text_dialog.dart';
import 'settings_parts.dart';

/// Opens the Studio's skills: reads them (from the Studio's folder, or from
/// [store]) and lists them.
Future<void> openStudioSkills(BuildContext context, {StudioStore? store}) async {
  final found = store ?? await StudioStore.open();
  if (!context.mounted) return;
  if (found == null) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('This device would not give the Studio a folder to keep '
          'its skills in.'),
    ));
    return;
  }
  final library = await StudioSkillLibrary.forDirectory(found.directory);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => StudioSkillsPage(library: library),
  ));
}

/// The Studio's skills, in the open Agent Skills format: what each is for, a
/// switch for each, and a way to bring more in. Every agent is told about the
/// skills that are on, and loads one when the work matches it.
class StudioSkillsPage extends StatelessWidget {
  const StudioSkillsPage({super.key, required this.library});

  final StudioSkillLibrary library;

  Future<void> _restore(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore the starter skills?'),
        content: const Text('The skills MaiChat ships are put back as they '
            'came — edited ones reset, deleted ones returned. Your own skills '
            'stay as they are.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok == true) await library.restoreStarters();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final skills = library.skills;
        final problems = library.problems;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Skills'),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'restore') unawaited(_restore(context));
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'restore',
                    child: Text('Restore starter skills'),
                  ),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            key: const Key('studio-skills-add'),
            onPressed: () => showSkillImportSheet(context, library),
            icon: const Icon(Icons.add),
            label: const Text('Add skill'),
          ),
          body: ListView(
            padding: settingsPagePadding(context, fab: true),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Text(
                  'Skills are instructions for particular kinds of work. The '
                  'Studio sees only their names and descriptions until the '
                  'work calls for one. Type / in the composer to use one '
                  'yourself.',
                  style: muted,
                ),
              ),
              const SizedBox(height: 8),
              if (skills.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
                  child: Column(
                    children: [
                      Icon(Icons.auto_stories_outlined,
                          size: 48, color: theme.colorScheme.primary),
                      const SizedBox(height: 16),
                      Text('No skills yet.', style: muted),
                    ],
                  ),
                )
              else
                SettingsGroup(
                  title: '${library.enabled.length} of ${skills.length} on',
                  children: [
                    for (final s in skills)
                      _SkillRow(library: library, skill: s),
                  ],
                ),
              if (problems.isNotEmpty)
                SettingsGroup(
                  title: 'Could not be read',
                  children: [
                    for (final p in problems)
                      ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
                        leading: Icon(Icons.error_outline,
                            color: theme.colorScheme.error),
                        title: Text(p.folder),
                        subtitle: Text(p.message),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SkillRow extends StatelessWidget {
  const _SkillRow({required this.library, required this.skill});

  final StudioSkillLibrary library;
  final StudioSkill skill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      key: ValueKey('skill-${skill.name}'),
      contentPadding: const EdgeInsets.fromLTRB(20, 10, 12, 10),
      title: Row(
        children: [
          Flexible(child: Text(skill.name, overflow: TextOverflow.ellipsis)),
          if (skill.isStarter) ...[
            const SizedBox(width: 8),
            const _Tag('Starter'),
          ],
        ],
      ),
      subtitle: Text(
        skill.description,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: Switch(
        key: ValueKey('skill-switch-${skill.name}'),
        value: skill.enabled,
        onChanged: (v) => library.setEnabled(skill.name, v),
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => StudioSkillDetailPage(library: library, name: skill.name),
      )),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onTertiaryContainer),
      ),
    );
  }
}

/// One skill: what it is for, its instructions as they read, and its files.
class StudioSkillDetailPage extends StatelessWidget {
  const StudioSkillDetailPage({
    super.key,
    required this.library,
    required this.name,
  });

  final StudioSkillLibrary library;
  final String name;

  Future<void> _delete(BuildContext context, StudioSkill skill) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${skill.name}?'),
        content: Text(skill.isStarter
            ? 'It can be brought back with Restore starter skills.'
            : 'Its folder and every file in it are deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    Navigator.of(context).pop();
    await library.delete(skill.name);
  }

  Future<void> _export(BuildContext context, StudioSkill skill) async {
    final messenger = ScaffoldMessenger.of(context);
    String? path;
    try {
      path = await FilePicker.saveFile(
        dialogTitle: 'Save skill',
        fileName: '${skill.name}.zip',
        bytes: library.exportZip(skill.name),
        type: FileType.custom,
        allowedExtensions: const ['zip'],
      );
    } catch (_) {
      path = null;
    }
    messenger.showSnackBar(SnackBar(
      content: Text(path == null ? 'Not saved.' : 'Saved ${skill.name}.zip.'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: library,
      builder: (context, _) {
        final skill = library.skill(name);
        if (skill == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('This skill is gone.')),
          );
        }
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final muted =
            theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
        final base = (theme.textTheme.bodyMedium ?? const TextStyle())
            .copyWith(color: scheme.onSurface, height: 1.45);
        final styles = MarkdownStyles(
          base: base,
          emphasis: scheme.onSurface,
          quote: scheme.onSurface,
          codeBackground: scheme.surfaceContainerHighest,
          codeForeground: scheme.onSurface,
          link: scheme.primary,
        );
        return Scaffold(
          appBar: AppBar(
            title: Text(skill.name),
            actions: [
              IconButton(
                tooltip: 'Edit',
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        StudioSkillEditPage(library: library, skill: skill),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'export' => unawaited(_export(context, skill)),
                  _ => unawaited(_delete(context, skill)),
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'export', child: Text('Save as zip')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
          body: ListView(
            padding: settingsPagePadding(context),
            children: [
              SettingsGroup(children: [
                SwitchListTile(
                  contentPadding: const EdgeInsets.fromLTRB(20, 8, 16, 8),
                  title: const Text('On'),
                  subtitle: const Text('Agents are told about it and can use '
                      'it; /name uses it now.'),
                  value: skill.enabled,
                  onChanged: (v) => library.setEnabled(skill.name, v),
                ),
              ]),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(skill.description, style: theme.textTheme.bodyLarge),
              ),
              if (skill.warnings.isNotEmpty || skill.hasScripts) ...[
                const SizedBox(height: 16),
                for (final w in [
                  ...skill.warnings,
                  if (skill.hasScripts)
                    'Its scripts cannot run here; agents can read them, not '
                        'run them.',
                ])
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 18, color: scheme.tertiary),
                        const SizedBox(width: 10),
                        Expanded(child: Text(w, style: muted)),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: SelectableText.rich(
                  TextSpan(children: buildMessageSpans(skill.body, styles)),
                ),
              ),
              if (skill.files.isNotEmpty)
                SettingsGroup(
                  title: 'Files',
                  children: [
                    for (final f in skill.files)
                      ListTile(
                        contentPadding: const EdgeInsets.fromLTRB(20, 4, 16, 4),
                        leading: Icon(
                          f.startsWith('scripts/')
                              ? Icons.code_off_outlined
                              : Icons.description_outlined,
                        ),
                        title: Text(f),
                      ),
                  ],
                ),
              if (skill.license.isNotEmpty ||
                  skill.compatibility.isNotEmpty) ...[
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    [
                      if (skill.license.isNotEmpty) 'Licence: ${skill.license}',
                      if (skill.compatibility.isNotEmpty) skill.compatibility,
                    ].join(' · '),
                    style: muted,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Writing a skill by hand, or editing one: its name, when to use it, and
/// the instructions. The instructions box is a fixed height and scrolls
/// inside, like the creator's long fields.
class StudioSkillEditPage extends StatefulWidget {
  const StudioSkillEditPage({super.key, required this.library, this.skill});

  final StudioSkillLibrary library;
  final StudioSkill? skill;

  @override
  State<StudioSkillEditPage> createState() => _StudioSkillEditPageState();
}

class _StudioSkillEditPageState extends State<StudioSkillEditPage> {
  late final TextEditingController _name =
      TextEditingController(text: widget.skill?.name ?? '');
  late final TextEditingController _description =
      TextEditingController(text: widget.skill?.description ?? '');
  late final TextEditingController _body =
      TextEditingController(text: widget.skill?.body ?? '');
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final old = widget.skill;
    final skill = StudioSkill(
      name: _name.text.trim(),
      description: _description.text.trim(),
      body: _body.text.trim(),
      license: old?.license ?? '',
      compatibility: old?.compatibility ?? '',
      // An edited starter keeps its origin, so Restore can still reset it.
      metadata: old?.metadata ?? const <String, String>{},
      allowedTools: old?.allowedTools ?? const <String>[],
      enabled: old?.enabled ?? true,
    );
    try {
      await widget.library.save(skill, previousName: old?.name);
      if (mounted) Navigator.of(context).pop();
    } on SkillImportException catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.skill == null ? 'New skill' : 'Edit skill'),
        actions: [
          TextButton(
            key: const Key('studio-skill-save'),
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: settingsPagePadding(context),
        children: [
          TextField(
            key: const Key('studio-skill-name'),
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              helperText: 'Lower-case words joined by hyphens: '
                  'greeting-variety. It is also its /command.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            key: const Key('studio-skill-description'),
            controller: _description,
            minLines: 2,
            maxLines: 4,
            maxLength: kSkillDescriptionMax,
            decoration: const InputDecoration(
              labelText: 'When to use it',
              helperText: 'What it does and when an agent should load it.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 360,
            child: TextField(
              key: const Key('studio-skill-body'),
              controller: _body,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              decoration: const InputDecoration(
                labelText: 'Instructions',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

/// How a skill comes in: a `.md` or `.zip` file off the device, a link (a
/// `SKILL.md`, or a GitHub folder), text pasted in, or written by hand.
Future<void> showSkillImportSheet(
  BuildContext context,
  StudioSkillLibrary library,
) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetRow(
                key: const Key('skill-import-file'),
                icon: Icons.folder_open_outlined,
                title: 'From a file',
                subtitle: 'A SKILL.md, or a .zip of a skill folder',
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_importFile(context, library));
                },
              ),
              _SheetRow(
                key: const Key('skill-import-link'),
                icon: Icons.link,
                title: 'From a link',
                subtitle: 'A SKILL.md address, or a GitHub folder',
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_importLink(context, library));
                },
              ),
              _SheetRow(
                key: const Key('skill-import-paste'),
                icon: Icons.content_paste,
                title: 'Paste',
                subtitle: 'The text of a SKILL.md',
                onTap: () {
                  Navigator.of(sheet).pop();
                  unawaited(_importPaste(context, library));
                },
              ),
              _SheetRow(
                key: const Key('skill-import-write'),
                icon: Icons.edit_note,
                title: 'Write one',
                subtitle: 'A name, when to use it, and the instructions',
                onTap: () {
                  Navigator.of(sheet).pop();
                  Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => StudioSkillEditPage(library: library),
                  ));
                },
              ),
            ],
          ),
        ),
      ),
    );

class _SheetRow extends StatelessWidget {
  const _SheetRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SettingsLink(
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: onTap,
      );
}

/// Runs [bring] and reports how it went; a skill of the same name asks
/// whether to replace it.
Future<void> _bringIn(
  BuildContext context,
  Future<StudioSkill> Function(bool replace) bring,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final skill = await bring(false);
    messenger.showSnackBar(SnackBar(content: Text('Added ${skill.name}.')));
  } on SkillConflictException catch (e) {
    if (!context.mounted) return;
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Replace ${e.name}?'),
        content: const Text('You already have a skill of that name. The new '
            'one takes its place.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep mine'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (replace != true) return;
    try {
      final skill = await bring(true);
      messenger.showSnackBar(SnackBar(content: Text('Replaced ${skill.name}.')));
    } on SkillImportException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  } on SkillImportException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  }
}

Future<void> _importFile(BuildContext context, StudioSkillLibrary library) async {
  FilePickerResult? result;
  try {
    // By path, never withData: the file is read only once its size is known.
    result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['md', 'zip'],
    );
  } catch (_) {
    result = null;
  }
  final path = result?.files.single.path;
  if (path == null || !context.mounted) return;
  final file = File(path);
  if (file.lengthSync() > kSkillImportMax) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('That file is too big to be a skill.'),
    ));
    return;
  }
  final bytes = await file.readAsBytes();
  if (!context.mounted) return;
  final isZip = bytes.length > 3 && bytes[0] == 0x50 && bytes[1] == 0x4b;
  await _bringIn(
    context,
    (replace) => isZip
        ? library.importZip(bytes, replace: replace)
        : library.importMarkdown(
            utf8.decode(bytes, allowMalformed: true),
            replace: replace,
          ),
  );
}

Future<void> _importLink(BuildContext context, StudioSkillLibrary library) async {
  final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
  if (!context.mounted) return;
  final link = await showStudioTextDialog(
    context,
    title: 'Add a skill from a link',
    initial: clip.startsWith('http') ? clip : '',
    hint: 'https://github.com/owner/repo/tree/main/skills/…',
  );
  if (link == null || link.trim().isEmpty || !context.mounted) return;
  await _bringIn(context, (replace) => library.importUrl(link, replace: replace));
}

Future<void> _importPaste(BuildContext context, StudioSkillLibrary library) async {
  final text = await showStudioTextDialog(
    context,
    title: 'Paste a SKILL.md',
    initial: '',
    tall: true,
    hint: '---\nname: my-skill\ndescription: …\n---\n\nInstructions…',
  );
  if (text == null || text.trim().isEmpty || !context.mounted) return;
  await _bringIn(context, (replace) => library.importMarkdown(text, replace: replace));
}
