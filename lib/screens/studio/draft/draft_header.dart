import 'package:flutter/material.dart';

import '../../../models/character.dart';
import '../../../models/chat_interface.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/character_avatar.dart';
import '../../../widgets/natural_image.dart';

/// Wider than this (width ÷ height) and a picture counts as landscape.
const double kDraftLandscapeRatio = 1.15;

/// How wide the picture is drawn when it sits beside the name.
const double kDraftSideAvatarWidth = 132;

/// The top of every Draft tab: the character's picture and who they are,
/// arranged by the picture's own shape.
///
/// A square or portrait picture sits at the top right with the name, title and
/// tags beside it on the left; a landscape one takes the whole width with them
/// underneath. The shape is read from the app-wide ratio cache first, so a
/// picture measured anywhere else opens in the right arrangement; one seen for
/// the first time starts beside the name and moves once it has been measured.
class DraftHeader extends StatefulWidget {
  const DraftHeader({super.key, required this.character});

  final Character character;

  @override
  State<DraftHeader> createState() => _DraftHeaderState();
}

class _DraftHeaderState extends State<DraftHeader> {
  double? _ratio;
  String _ref = '';

  String get _avatar => widget.character.avatar.trim();

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(DraftHeader old) {
    super.didUpdateWidget(old);
    if (_ref != _avatar) _sync();
  }

  void _sync() {
    _ref = _avatar;
    _ratio = _ref.isEmpty ? null : avatarRatio(_ref);
  }

  void _resolved(double ratio) {
    if (!mounted || ratio == _ratio) return;
    setState(() => _ratio = ratio);
  }

  bool get _landscape => (_ratio ?? 1) > kDraftLandscapeRatio;

  @override
  Widget build(BuildContext context) {
    final c = widget.character;
    final info = _Identity(character: c);
    if (_avatar.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: info),
            const SizedBox(width: 16),
            CharacterAvatar(
              character: c,
              size: 96,
              shape: AvatarShape.rounded,
              corner: CornerRounding.xl,
            ),
          ],
        ),
      );
    }
    final picture = ClipRRect(
      key: const ValueKey('draft-header-picture'),
      borderRadius: BorderRadius.circular(24),
      child: NaturalImage(
        imageRef: _avatar,
        placeholderRatio: _ratio ?? 1,
        maxHeightFactor: _landscape ? 0.4 : 0.32,
        displayWidth: _landscape ? null : kDraftSideAvatarWidth,
        onRatioResolved: _resolved,
        fallback: CharacterAvatar(
          character: c,
          size: kDraftSideAvatarWidth,
          shape: AvatarShape.square,
        ),
      ),
    );
    if (_landscape) {
      return Padding(
        key: const ValueKey('draft-header-landscape'),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [picture, const SizedBox(height: 14), info],
        ),
      );
    }
    return Padding(
      key: const ValueKey('draft-header-side'),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: info),
          const SizedBox(width: 16),
          SizedBox(width: kDraftSideAvatarWidth, child: picture),
        ],
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = character;
    final named = c.name.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          named ? c.name.trim() : 'Not named yet',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: named ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (c.title.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            c.title.trim(),
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        if (c.tags.isNotEmpty) ...[
          const SizedBox(height: 10),
          DraftTagStrip(tags: c.tags),
        ],
      ],
    );
  }
}

/// The tags as one sideways-scrolling line of chips — the same band the
/// character sheet draws, sized for a column rather than the whole page.
class DraftTagStrip extends StatelessWidget {
  const DraftTagStrip({super.key, required this.tags, this.padding = EdgeInsets.zero});

  final List<String> tags;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: Row(
        children: [
          for (final tag in tags)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Chip(
                label: Text(tag),
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }
}
