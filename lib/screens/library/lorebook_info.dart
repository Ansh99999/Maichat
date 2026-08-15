import 'package:flutter/material.dart';

/// The "Info on Lorebooks" panel that closes the lorebook editor.
///
/// A lorebook only makes sense once you know *when* its entries are used, and
/// the two number fields (priority and weight) are the classic place people get
/// it wrong — so the editor explains itself rather than assuming the user has
/// read SillyTavern's or Agnai's docs. It lives in its own file because it is
/// prose, not form plumbing, and it is folded away by default so it never gets
/// between the author and the entries.
class LorebookInfoTile extends StatelessWidget {
  const LorebookInfoTile({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final body = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(color: scheme.onSurfaceVariant, height: 1.45);

    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.info_outline),
        title: const Text('Info on Lorebooks'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: [
          for (final paragraph in _paragraphs)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(paragraph, style: body),
            ),
        ],
      ),
    );
  }
}

/// The documentation itself, in the order a newcomer needs it: what the thing
/// is, when it fires, what the two numbers do, how keywords are matched, and
/// how books travel between apps. Every sentence describes behaviour this app
/// actually has — nothing aspirational.
const List<String> _paragraphs = <String>[
  'A lorebook is a set of facts about your world — places, people, history, '
      'house rules — kept outside the character card so several chats and '
      'several characters can share it.',
  'Nothing in a book is sent to the model by default. An entry is injected into '
      'the prompt only when one of its keywords turns up in the recent chat, so '
      'a large book costs nothing until the conversation actually touches it.',
  'Priority decides what survives. When more entries match than the token '
      'budget allows, the highest priority is kept and the lowest is dropped '
      'first. Weight decides ordering among the entries that were kept: the '
      'highest weight ends up closest to the reply, which is the position a '
      'model pays most attention to.',
  'Keywords are matched without regard to case, and as whole words — "cat" '
      'matches "the cat sat" but not "concatenate". An asterisk stands for any '
      'run of letters or digits and a question mark for a single one, so '
      '"dragon*" also matches "dragonfire". A keyword written between slashes, '
      'such as /dragon(s|fire)?/i, is used as a regular expression instead.',
  'An entry imported from SillyTavern may be marked always-on there, in which '
      'case it is injected every turn without matching anything. Those entries '
      'keep working here; this editor just has no switch for making one.',
  'A chat can run several lorebooks at once. They are scanned together and '
      'share one token budget, so priority is compared across every active '
      'book rather than within one.',
  'Books import and export in SillyTavern World Info and Agnai memory-book '
      'formats, as well as this app\'s own format, which keeps the extras the '
      'other two have no field for (the picture, the colour and the tags).',
];
