import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../services/studio/studio_controller.dart';
import '../../../services/studio/studio_images.dart';
import '../../../widgets/avatar_image.dart';
import '../../../widgets/smooth_image.dart';
import 'draft_widgets.dart';

/// What the add-picture sheet was left with.
enum AddPictureChoice {
  /// The user wants their gallery: the caller opens its picker.
  gallery,

  /// A picture from the web was filed and put on the character.
  added,
}

/// The Images tab's "Add picture": three roomy ways in — the user's gallery,
/// a link to any page or picture (Pinterest, DeviantArt, ArtStation, a blog),
/// or a search of openly licensed pictures. A web picture is previewed with
/// its credit before anything is saved; saving files it in the gallery (a
/// file, with where it came from) and puts it on the draft as a hand edit, so
/// it can be rewound.
Future<AddPictureChoice?> showAddPictureSheet(
  BuildContext context, {
  required StudioController controller,
  StudioImages? images,
}) =>
    showModalBottomSheet<AddPictureChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      builder: (_) => AddPictureSheet(
        controller: controller,
        images: images ?? StudioImages.shared,
      ),
    );

enum _Page { menu, link, search, preview }

/// The body of [showAddPictureSheet], exposed for tests.
class AddPictureSheet extends StatefulWidget {
  const AddPictureSheet({
    super.key,
    required this.controller,
    required this.images,
  });

  final StudioController controller;
  final StudioImages images;

  @override
  State<AddPictureSheet> createState() => _AddPictureSheetState();
}

class _AddPictureSheetState extends State<AddPictureSheet> {
  final TextEditingController _link = TextEditingController();
  final TextEditingController _query = TextEditingController();

  _Page _page = _Page.menu;

  /// Which way the last page change went, for the direction pages slide.
  bool _forward = true;

  /// The page the preview was opened from, which Back returns to.
  _Page _previewFrom = _Page.menu;

  ImageSource _source = ImageSource.openverse;
  List<ImageCandidate>? _results;
  WebPicture? _picture;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _link.dispose();
    _query.dispose();
    super.dispose();
  }

  void _go(_Page page, {bool forward = true}) => setState(() {
        _page = page;
        _forward = forward;
        _error = null;
      });

  void _back() {
    switch (_page) {
      case _Page.preview:
        _go(_previewFrom, forward: false);
      case _Page.link || _Page.search:
        _go(_Page.menu, forward: false);
      case _Page.menu:
        Navigator.of(context).pop();
    }
  }

  Future<void> _run(Future<void> Function() job) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await job();
    } on ImageError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    _link.text = text;
    _link.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> _findLink() => _run(() async {
        final url = _link.text.trim();
        if (url.isEmpty) throw ImageError('Paste a link first.');
        final picture = await widget.images.fetchPicture(url);
        if (!mounted) return;
        _picture = picture;
        _previewFrom = _Page.link;
        _go(_Page.preview);
      });

  Future<void> _search() => _run(() async {
        FocusScope.of(context).unfocus();
        final found =
            await widget.images.search(_query.text, source: _source, limit: 12);
        if (!mounted) return;
        setState(() => _results = found);
        if (found.isEmpty) {
          setState(() => _error = 'Nothing found. Try fewer or plainer words, '
              'or the other source.');
        }
      });

  Future<void> _pick(ImageCandidate candidate) => _run(() async {
        final fetched = await widget.images.fetchPicture(candidate.url);
        if (!mounted) return;
        _picture = WebPicture(
          bytes: fetched.bytes,
          mime: fetched.mime,
          url: fetched.url,
          page: candidate.page,
          title: candidate.title,
          credit: candidate.credit,
        );
        _previewFrom = _Page.search;
        _go(_Page.preview);
      });

  Future<void> _save({required bool avatar}) => _run(() async {
        final picture = _picture;
        if (picture == null) return;
        final controller = widget.controller;
        final record = await filePictureFromWeb(
          controller.state,
          picture,
          characterId: controller.session.workspace.character.id,
        );
        if (record == null) {
          throw ImageError('There is nowhere on this device to keep the '
              'picture.');
        }
        final host =
            Uri.tryParse(picture.source)?.host.replaceFirst('www.', '') ??
                'the web';
        controller.editByHand(
          avatar
              ? 'Set a picture from $host as the avatar by hand'
              : 'Added a picture from $host by hand',
          (ws) {
            final c = ws.character;
            final ref = record.image;
            if (avatar || !c.hasAvatar) {
              c.avatars.remove(ref);
              if (c.hasAvatar && c.avatar != ref && !c.avatars.contains(c.avatar)) {
                c.avatars.insert(0, c.avatar);
              }
              c.avatar = ref;
            } else if (!c.avatars.contains(ref)) {
              c.avatars.add(ref);
            }
          },
        );
        if (mounted) Navigator.of(context).pop(AddPictureChoice.added);
      });

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(context),
          Flexible(
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Easing.emphasizedDecelerate,
                switchOutCurve: Easing.emphasizedAccelerate,
                layoutBuilder: (current, previous) => Stack(
                  alignment: Alignment.topCenter,
                  children: [...previous, ?current],
                ),
                // A page slides in from the side it is going toward, the old
                // one out the other way; nothing fades.
                transitionBuilder: (child, animation) {
                  final incoming = child.key == ValueKey<_Page>(_page);
                  final from = (_forward ? 1.0 : -1.0) * (incoming ? 1 : -1);
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: Offset(from, 0),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey<_Page>(_page),
                  child: switch (_page) {
                    _Page.menu => _menu(context),
                    _Page.link => _linkPage(context),
                    _Page.search => _searchPage(context),
                    _Page.preview => _previewPage(context),
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final title = switch (_page) {
      _Page.menu => 'Add a picture',
      _Page.link => 'From a link',
      _Page.search => 'Search the web',
      _Page.preview => 'Use this picture?',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, kDraftGutter, 8),
      child: Row(
        children: [
          if (_page != _Page.menu)
            IconButton(
              key: const Key('add-picture-back'),
              tooltip: 'Back',
              onPressed: _busy ? null : _back,
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: 12),
          Expanded(
            child: Text(title, style: theme.textTheme.titleLarge),
          ),
        ],
      ),
    );
  }

  Widget _menu(BuildContext context) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(kDraftGutter, 8, kDraftGutter, 28),
        children: [
          _Choice(
            key: const Key('add-picture-gallery'),
            icon: Icons.photo_library_outlined,
            title: 'From your gallery',
            subtitle: 'Pictures you have uploaded, made or saved.',
            onTap: () =>
                Navigator.of(context).pop(AddPictureChoice.gallery),
          ),
          const SizedBox(height: 12),
          _Choice(
            key: const Key('add-picture-link'),
            icon: Icons.add_link,
            title: 'From a link',
            subtitle: 'Pinterest, DeviantArt, ArtStation — any page or '
                'picture.',
            onTap: () => _go(_Page.link),
          ),
          const SizedBox(height: 12),
          _Choice(
            key: const Key('add-picture-search'),
            icon: Icons.image_search_outlined,
            title: 'Search the web',
            subtitle: 'Openly licensed pictures, with their creators.',
            onTap: () => _go(_Page.search),
          ),
        ],
      );

  Widget _linkPage(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(kDraftGutter, 8, kDraftGutter, 28),
      children: [
        TextField(
          key: const Key('add-picture-link-field'),
          controller: _link,
          autofocus: true,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _busy ? null : _findLink(),
          decoration: InputDecoration(
            hintText: 'https://…',
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              key: const Key('add-picture-paste'),
              tooltip: 'Paste',
              onPressed: _busy ? null : _paste,
              icon: const Icon(Icons.content_paste),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Paste the link to a pin, a post or the picture itself. The picture '
          'is saved to your gallery with where it came from.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        _status(context),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            key: const Key('add-picture-find'),
            onPressed: _busy ? null : _findLink,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 52)),
            icon: const Icon(Icons.travel_explore),
            label: const Text('Find the picture'),
          ),
        ),
      ],
    );
  }

  Widget _searchPage(BuildContext context) {
    final theme = Theme.of(context);
    final results = _results;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(kDraftGutter, 8, kDraftGutter, 28),
      children: [
        TextField(
          key: const Key('add-picture-query'),
          controller: _query,
          autofocus: results == null,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _busy ? null : _search(),
          decoration: InputDecoration(
            hintText: 'What should it show?',
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            suffixIcon: IconButton(
              key: const Key('add-picture-run-search'),
              tooltip: 'Search',
              onPressed: _busy ? null : _search,
              icon: const Icon(Icons.search),
            ),
          ),
        ),
        const SizedBox(height: 12),
        SegmentedButton<ImageSource>(
          segments: [
            for (final s in ImageSource.values)
              ButtonSegment(value: s, label: Text(s.label)),
          ],
          selected: {_source},
          showSelectedIcon: false,
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() {
                    _source = s.first;
                    _results = null;
                  }),
        ),
        _status(context),
        if (results != null && results.isNotEmpty) ...[
          const SizedBox(height: 20),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 16,
            crossAxisSpacing: 12,
            childAspectRatio: 0.78,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < results.length; i++)
                _Result(
                  key: ValueKey('add-picture-result-$i'),
                  candidate: results[i],
                  onTap: _busy ? null : () => _pick(results[i]),
                ),
            ],
          ),
        ] else if (results == null) ...[
          const SizedBox(height: 16),
          Text(
            'Pinterest, DeviantArt and ArtStation cannot be searched from '
            'here — use "From a link" for those.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _previewPage(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final picture = _picture;
    if (picture == null) return const SizedBox.shrink();
    final host = Uri.tryParse(picture.source)?.host.replaceFirst('www.', '');
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(kDraftGutter, 8, kDraftGutter, 28),
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(kDraftOuterRadius),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.42,
            ),
            child: ColoredBox(
              color: scheme.surfaceContainerHighest,
              child: Image.memory(
                picture.bytes,
                key: const Key('add-picture-preview'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                // A format the device cannot draw still saves as a file; say
                // so rather than leaving a blank box.
                errorBuilder: (_, _, _) => SizedBox(
                  height: 160,
                  child: Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: scheme.outline,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        if (picture.title.trim().isNotEmpty)
          Text(
            picture.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium,
          ),
        const SizedBox(height: 4),
        Text(
          [
            if (picture.credit.trim().isNotEmpty) picture.credit.trim(),
            if (host != null && host.isNotEmpty && !picture.credit.contains(host))
              host,
          ].join(' · '),
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        _status(context),
        const SizedBox(height: 24),
        FilledButton.icon(
          key: const Key('add-picture-set-avatar'),
          onPressed: _busy ? null : () => _save(avatar: true),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          icon: const Icon(Icons.account_circle_outlined),
          label: const Text('Set as avatar'),
        ),
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          key: const Key('add-picture-add-pool'),
          onPressed: _busy ? null : () => _save(avatar: false),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
          icon: const Icon(Icons.add_photo_alternate_outlined),
          label: const Text('Add to pictures'),
        ),
      ],
    );
  }

  /// The busy bar or the error line, whichever applies — a progress line
  /// rather than a blocking spinner, so the sheet can still be closed.
  Widget _status(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: LinearProgressIndicator(key: Key('add-picture-busy')),
      );
    }
    final error = _error;
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(
        error,
        key: const Key('add-picture-error'),
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: scheme.error),
      ),
    );
  }
}

/// One of the three ways in: a large, soft card with an icon, a title and one
/// line.
class _Choice extends StatelessWidget {
  const _Choice({
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(kDraftOuterRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(icon, color: scheme.onSecondaryContainer),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// One search result: the thumbnail, and its credit on one line.
class _Result extends StatelessWidget {
  const _Result({super.key, required this.candidate, this.onTap});

  final ImageCandidate candidate;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final image = avatarImage(
      candidate.thumbnail,
      displaySize: 200,
      devicePixelRatio: dpr,
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: SizedBox.expand(
                  child: image == null
                      ? Icon(Icons.image_outlined, color: scheme.outline)
                      : SmoothImage(
                          image: image,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Icon(
                            Icons.broken_image_outlined,
                            color: scheme.outline,
                          ),
                        ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            candidate.credit.isEmpty ? candidate.title : candidate.credit,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
