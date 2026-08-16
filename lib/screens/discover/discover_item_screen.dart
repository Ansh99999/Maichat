import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../../services/discover/discover_sources.dart';
import '../../state/app_state.dart';
import '../character_detail_screen.dart';
import '../library/lorebooks_screen.dart';
import '../presets/presets_screen.dart';
import 'discover_browser_sheet.dart';
import 'discover_card.dart';

/// A catalogue entry's page. Reads like a character's own page in MaiChat —
/// same header, same section-by-section persona — except the button downloads it
/// instead of starting a chat.
///
/// The definition is fetched as the page opens, because that is also what a
/// download needs: by the time the button is pressed the work is usually done.
/// When the site refuses (JannyAI's card API is Cloudflare-guarded from some
/// networks) the page still shows everything the feed knew, says what happened,
/// and lets the button try again.
class DiscoverItemScreen extends StatefulWidget {
  const DiscoverItemScreen({
    super.key,
    required this.item,
    required this.source,
  });

  final DiscoverItem item;
  final DiscoverSource source;

  @override
  State<DiscoverItemScreen> createState() => _DiscoverItemScreenState();
}

class _DiscoverItemScreenState extends State<DiscoverItemScreen> {
  DiscoverPayload? _payload;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  /// Set when the site answered with a bot check, which a browser view can pass.
  DiscoverChallengeException? _challenge;

  /// The local id of what was saved, so the button can turn into "Open".
  String? _savedCharacterId;
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Loads the definition, and — when the site answers with a bot check — goes
  /// through the browser view for it without waiting to be asked. The user came
  /// here to read this character; making them press a button to permit the only
  /// route that works is a toll, not a choice.
  Future<void> _load({bool allowBrowser = true}) async {
    setState(() {
      _loading = true;
      _error = null;
      _challenge = null;
    });
    try {
      final payload = await widget.source.fetch(widget.item);
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _loading = false;
      });
    } on DiscoverChallengeException catch (challenge) {
      if (!mounted) return;
      setState(() {
        _challenge = challenge;
        _error = challenge.message;
        _loading = false;
      });
      if (allowBrowser && webViewSupported) await _passCheck();
    } on DiscoverException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _loading = false;
      });
    }
  }

  /// A manual retry asks the source to forget which routes it found blocked, so
  /// a change of network gets a fresh answer.
  Future<void> _retry() async {
    widget.source.resetTransport();
    await _load();
  }

  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    var payload = _payload;
    if (payload == null) {
      try {
        payload = await widget.source.fetch(widget.item);
        if (!mounted) return;
        setState(() {
          _payload = payload;
          _error = null;
          _challenge = null;
        });
      } on DiscoverChallengeException catch (challenge) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _challenge = challenge;
          _error = challenge.message;
        });
        // The user asked for this download, so go straight to the one thing
        // that can complete it rather than making them find a second button.
        if (webViewSupported) {
          await _passCheck(thenSave: true);
        } else {
          _say(challenge.message);
        }
        return;
      } on DiscoverException catch (error) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _error = error.message;
        });
        _say(error.message);
        return;
      }
    }
    await _save(payload);
  }

  /// Opens the site in a browser view, lets it pass the check, then finishes the
  /// download from the page it was holding.
  Future<void> _passCheck({bool thenSave = false}) async {
    final challenge = _challenge;
    if (challenge == null) return;
    final html = await solveInBrowserView(
      context,
      url: challenge.pageUrl,
      siteLabel: widget.source.label,
    );
    if (!mounted) return;
    if (html == null) {
      _say('Cancelled — the check was not completed.');
      return;
    }
    setState(() => _saving = true);
    try {
      final payload = await widget.source.fetchFromHtml(widget.item, html);
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _error = null;
        _challenge = null;
        _saving = false;
      });
      if (thenSave) await _save(payload);
    } on DiscoverException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
      _say(error.message);
    }
  }

  /// Files a fetched payload in the user's own library.
  Future<void> _save(DiscoverPayload payload) async {
    if (!mounted) return;
    setState(() => _saving = true);
    final state = context.read<AppState>();
    String message;
    VoidCallback? open;
    final character = payload.character;
    final lorebook = payload.lorebook;
    final preset = payload.preset;
    if (character != null) {
      await state.addCharacter(character);
      _savedCharacterId = character.id;
      message = '${character.displayName} added to Characters';
      open = () => _push(CharacterDetailScreen(characterId: character.id));
      // A card's own `character_book` rides along with it. Filing the character
      // and dropping its world info would look like a working download and
      // behave like a broken character.
      if (lorebook != null) {
        await state.addLorebook(lorebook);
        message = '${character.displayName} and its lorebook '
            '(${lorebook.entries.length} entries) added';
      }
    } else if (lorebook != null) {
      await state.addLorebook(lorebook);
      message = '${lorebook.name} added to Lorebooks';
      open = () => _push(const LorebooksScreen());
    } else if (preset != null) {
      await state.addPreset(preset);
      message = '${preset.name} added to Presets';
      open = () => _push(const PresetsScreen());
    } else {
      message = 'Nothing came back to download.';
      open = null;
    }

    if (!mounted) return;
    setState(() {
      _saving = false;
      _saved = open != null;
    });
    _say(message, actionLabel: open == null ? null : 'Open', onAction: open);
  }

  void _push(Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));

  void _say(String message, {String? actionLabel, VoidCallback? onAction}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        action: actionLabel == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction ?? () {}),
      ),
    );
  }

  Future<void> _openInBrowser() async {
    final link = widget.item.pageUrl ?? widget.source.homeUrl;
    final uri = Uri.tryParse(link);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _say('Could not open $link');
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final character = _payload?.character;

    return Scaffold(
      appBar: AppBar(
        title: Text(item.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Open on ${widget.source.label}',
            icon: const Icon(Icons.open_in_new),
            onPressed: _openInBrowser,
          ),
        ],
      ),
      floatingActionButton: _downloadButton(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 110),
        children: [
          _Header(item: item),
          _FactsCard(item: item, source: widget.source, payload: _payload),
          if (_loading) const _LoadingNote(),
          if (_error != null)
            _ErrorNote(
              message: _error!,
              onRetry: _retry,
              // A bot check has a real way through it; offer that instead of a
              // retry that will be refused the same way.
              onPassCheck:
                  _challenge != null && webViewSupported ? _passCheck : null,
            ),
          ..._details(character),
        ],
      ),
    );
  }

  Widget _downloadButton() {
    if (_saved) {
      final id = _savedCharacterId;
      return FloatingActionButton.extended(
        onPressed: () {
          if (id != null) {
            _push(CharacterDetailScreen(characterId: id));
          } else {
            _push(const LorebooksScreen());
          }
        },
        icon: const Icon(Icons.check),
        label: const Text('Downloaded'),
      );
    }
    return FloatingActionButton.extended(
      onPressed: _saving ? null : _download,
      icon: _saving
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined),
      label: Text(_saving ? 'Downloading…' : 'Download'),
    );
  }

  /// The definition, laid out exactly as a local character's page lays it out —
  /// the point is that this feels like the same app, not a web view.
  List<Widget> _details(Character? character) {
    final item = widget.item;
    final book = _payload?.lorebook;
    if (character != null) {
      return [
        _Section('Description', character.description),
        _Section('Personality', character.personality),
        _Section('Scenario', character.scenario),
        _Section('Greeting', character.firstMes),
        if (character.alternateGreetings.isNotEmpty)
          _Section(
            'Alternate greetings',
            character.alternateGreetings
                .asMap()
                .entries
                .map((e) => '${e.key + 1}. ${e.value}')
                .join('\n\n'),
          ),
        _Section('Example dialogue', character.mesExample),
        _Section('System prompt', character.systemPrompt),
        _Section(
            'Post-history instructions', character.postHistoryInstructions),
        _Section('Creator notes', character.creatorNotes),
      ];
    }
    if (book != null) {
      return [
        _Section('About', book.description),
        for (final entry in book.entries.take(8))
          _Section(
            entry.name.trim().isEmpty
                ? (entry.keys.isEmpty ? 'Entry' : entry.keys.join(', '))
                : entry.name,
            entry.content,
          ),
        if (book.entries.length > 8)
          _Section(
            'And more',
            '${book.entries.length - 8} further entries download with the book.',
          ),
      ];
    }
    // Nothing fetched yet: show what the listing itself said.
    return [
      _Section('Tagline', item.tagline),
      _Section('About', item.description),
    ];
  }
}

/// The header block: the art, the name, where it came from, and its tags.
class _Header extends StatelessWidget {
  const _Header({required this.item});

  final DiscoverItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final meta = <String>[
      if (item.creator.trim().isNotEmpty) 'by ${item.creator.trim()}',
      if (item.nsfw) '18+',
    ].join(' · ');

    return Column(
      children: [
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            width: 140,
            height: 140,
            child: DiscoverImage(
              url: item.bestImageUrl,
              fallbackIcon: item.kind == DiscoverKind.character
                  ? Icons.person_outline
                  : Icons.menu_book_outlined,
              size: 140,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          item.name,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (meta.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            meta,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (item.tags.isNotEmpty) ...[
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in item.tags.take(12))
                Chip(
                  label: Text(tag),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The numbers, in the same "FOR THIS CHAT" card shape the character page uses.
class _FactsCard extends StatelessWidget {
  const _FactsCard({
    required this.item,
    required this.source,
    required this.payload,
  });

  final DiscoverItem item;
  final DiscoverSource source;
  final DiscoverPayload? payload;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = payload?.lorebook?.entries.length ?? item.entryCount;
    final rows = <(IconData, String, String)>[
      (Icons.travel_explore_outlined, 'Source', source.label),
      if (item.downloads != null)
        (Icons.download_outlined, 'Downloads', compactCount(item.downloads!)),
      if (item.favourites != null && item.favourites! > 0)
        (Icons.favorite_outline, 'Favourites', compactCount(item.favourites!)),
      if (item.rating != null && item.rating! > 0)
        (
          Icons.star_outline,
          'Rating',
          '${item.rating!.toStringAsFixed(1)}'
              '${item.ratingCount != null && item.ratingCount! > 0 ? ' (${compactCount(item.ratingCount!)})' : ''}'
        ),
      if (item.tokens != null && item.tokens! > 0)
        (Icons.numbers_outlined, 'Tokens', compactCount(item.tokens!)),
      if (entries != null) (Icons.list_alt_outlined, 'Entries', '$entries'),
      if (item.updatedAt != null)
        (Icons.update_outlined, 'Updated', _date(item.updatedAt!)),
      if (item.updatedAt == null && item.createdAt != null)
        (Icons.event_outlined, 'Created', _date(item.createdAt!)),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'FROM THE CATALOGUE',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(rows[i].$1, size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Text(
                      '${rows[i].$2}: ',
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    Expanded(
                      child: Text(
                        rows[i].$3,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class _LoadingNote extends StatelessWidget {
  const _LoadingNote();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Text(
              'Fetching the full definition…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      );
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote({
    required this.message,
    required this.onRetry,
    this.onPassCheck,
  });

  final String message;
  final VoidCallback onRetry;

  /// Set when a browser view could get past what stopped us.
  final Future<void> Function()? onPassCheck;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blocked = onPassCheck != null;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Card(
        elevation: 0,
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    blocked
                        ? Icons.shield_outlined
                        : Icons.warning_amber_outlined,
                    size: 18,
                    color: scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      blocked
                          ? 'The site wants to check the browser'
                          : 'Could not read the definition',
                      style: Theme.of(context).textTheme.titleSmall
                          ?.copyWith(color: scheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                message,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onErrorContainer),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: onRetry,
                      child: const Text('Retry'),
                    ),
                    if (blocked)
                      FilledButton.tonal(
                        onPressed: () => onPassCheck!(),
                        child: const Text('Pass the check'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled block of body text, collapsed behind "Read more" when it is long —
/// the same treatment the local character page gives it.
class _Section extends StatefulWidget {
  const _Section(this.title, this.body);

  final String title;
  final String body;

  @override
  State<_Section> createState() => _SectionState();
}

class _SectionState extends State<_Section> {
  bool _expanded = false;

  static const int _collapsedLines = 5;
  static const int _threshold = 200;

  @override
  Widget build(BuildContext context) {
    final body = widget.body.trim();
    if (body.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final isLong = body.length > _threshold ||
        '\n'.allMatches(body).length >= _collapsedLines;
    final collapsed = isLong && !_expanded;

    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
          ),
          const SizedBox(height: 6),
          AnimatedSize(
            duration: const Duration(milliseconds: 150),
            alignment: Alignment.topCenter,
            child: Text(
              body,
              maxLines: collapsed ? _collapsedLines : null,
              overflow: collapsed ? TextOverflow.ellipsis : TextOverflow.clip,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          if (isLong)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(_expanded ? 'Read less' : 'Read more'),
              ),
            ),
        ],
      ),
    );
  }
}
