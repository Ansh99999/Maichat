import 'package:flutter/material.dart';

import '../../../models/chat_interface.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import 'controls.dart';
import 'spoke.dart';
import 'wrap_rules.dart';

/// How the words themselves render: their size, whether markdown is parsed at
/// all, the two colours that markup pass gives out of the box, and the user's own
/// wrapping rules.
///
/// Emphasis and quotes sit here rather than under Colours on purpose. A wrapping
/// rule is a pair of symbols with a colour and a choice about whether the symbols
/// show; asterisks and quotes are the two built-in cases of that, so they belong
/// beside the rules that generalise them — and all of it is inert while markdown
/// is off, which is a fact one page can state once.
class TextSpokePage extends StatelessWidget {
  const TextSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Text',
          scope: scope,
          resetLabel: 'Reset text to defaults',
          onReset: () {
            const d = ChatInterface();
            update(ui.copyWith(
              fontSize: d.fontSize,
              markdown: d.markdown,
              emphasisColor: null,
              quoteColor: null,
              textWrapRules: d.textWrapRules,
            ));
            notifySetting(context, 'Text back to defaults');
          },
          children: _children(context, ui, update),
        ),
      );
  List<Widget> _children(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return [
      SettingSlider(
        icon: Icons.format_size_outlined,
        label: 'Font size',
        value: ui.fontSize,
        min: kMinFontSize,
        max: kMaxFontSize,
        suffix: '${ui.fontSize.round()} px',
        onChanged: (v) => update(ui.copyWith(fontSize: v)),
      ),
      SettingSwitch(
        icon: Icons.text_format_outlined,
        title: 'Markdown',
        subtitle: 'Render **bold**, *italic*, `code`, lists and quotes',
        value: ui.markdown,
        onChanged: (v) => update(ui.copyWith(markdown: v)),
      ),
      const Divider(height: 24),
      settingHeader(context, 'Markup colours'),
      SettingColorRow(
        label: 'Emphasis (*italic* / **bold**)',
        value: ui.emphasisColor,
        fallback: scheme.onSurface,
        onChanged: (c) => update(ui.copyWith(emphasisColor: c)),
      ),
      SettingColorRow(
        label: 'Quoted "text"',
        value: ui.quoteColor,
        fallback: scheme.onSurface,
        onChanged: (c) => update(ui.copyWith(quoteColor: c)),
      ),
      const Divider(height: 24),
      settingHeader(context, 'Text wrapping'),
      TextWrapSection(
        rules: ui.textWrapRules,
        markdown: ui.markdown,
        onChanged: (rules) => update(ui.copyWith(textWrapRules: rules)),
      ),
    ];
  }
}

