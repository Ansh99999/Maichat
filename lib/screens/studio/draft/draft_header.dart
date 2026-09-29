import 'package:flutter/material.dart';

import '../../../models/character.dart';
import '../../../models/chat_interface.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/character_avatar.dart';
import '../../../widgets/natural_image.dart';
import 'draft_widgets.dart';

/// Wider than this (width ÷ height) and a picture counts as landscape.
const double kDraftLandscapeRatio = 1.15;

/// How wide the picture is drawn when it sits beside the name.
const double kDraftSideAvatarWidth = 120;

/// The top of the Draft's Character tab: the character's picture and who they
/// are, arranged by the picture's own shape. (Only that tab: the others are
/// about their own part of the draft, and repeating the face on each was the
/// same block of information six times over.)
///
/// A square or portrait picture sits at the top left with the name, title and
/// tags beside it on the right; a landscape one takes the whole width with them
/// underneath. The shape is read from the app-wide ratio cache first, so a
/// picture measured anywhere else opens in the right arrangement; one seen for
/// the first time starts beside the name and moves once it has been measured.
/// That move is a height change on an [AnimatedSize], never a fade.
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
    const padding = EdgeInsets.fromLTRB(kDraftGutter, 8, kDraftGutter, 8);
    Widget child;
    if (_avatar.isEmpty) {
      child = Row(
        key: const ValueKey('draft-header-empty'),
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CharacterAvatar(
            character: c,
            size: 88,
            shape: AvatarShape.rounded,
            corner: CornerRounding.xl,
          ),
          const SizedBox(width: 20),
          Expanded(child: info),
        ],
      );
    } else {
      final picture = ClipRRect(
        key: const ValueKey('draft-header-picture'),
        borderRadius: BorderRadius.circular(kDraftOuterRadius),
        child: NaturalImage(
          imageRef: _avatar,
          placeholderRatio: _ratio ?? 1,
          maxHeightFactor: _landscape ? 0.36 : 0.3,
          displayWidth: _landscape ? null : kDraftSideAvatarWidth,
          onRatioResolved: _resolved,
          fallback: CharacterAvatar(
            character: c,
            size: kDraftSideAvatarWidth,
            shape: AvatarShape.square,
          ),
        ),
      );
      child = _landscape
          ? Column(
              key: const ValueKey('draft-header-landscape'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [picture, const SizedBox(height: 20), info],
            )
          : Row(
              key: const ValueKey('draft-header-side'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: kDraftSideAvatarWidth, child: picture),
                const SizedBox(width: 20),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: info,
                  ),
                ),
              ],
            );
    }
    return Padding(
      padding: padding,
      child: AnimatedSize(
        duration: kDraftFoldDuration,
        curve: kDraftFoldCurve,
        alignment: Alignment.topLeft,
        child: child,
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
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: named ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (c.title.trim().isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            c.title.trim(),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (c.tags.isNotEmpty) ...[
          const SizedBox(height: 14),
          DraftTagStrip(tags: c.tags),
        ],
      ],
    );
  }
}

/// The tags as one sideways-scrolling line of chips — the same band the
/// character sheet draws, sized for a column rather than the whole page.
class DraftTagStrip extends StatelessWidget {
  const DraftTagStrip({
    super.key,
    required this.tags,
    this.padding = EdgeInsets.zero,
  });

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
              padding: const EdgeInsets.only(right: 8),
              child: Chip(
                label: Text(tag),
                shape: const StadiumBorder(),
                side: BorderSide.none,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.secondaryContainer,
                labelStyle: TextStyle(
                  color: Theme.of(context).colorScheme.onSecondaryContainer,
                ),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }
}
