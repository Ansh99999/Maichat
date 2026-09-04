import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/character.dart';
import '../../models/discover.dart';
import '../../models/lorebook.dart';
import '../../services/discover/discover_sources.dart';
import '../../state/app_state.dart';
import '../../widgets/natural_image.dart';
import '../character_sheet_parts.dart';
import '../character_sheet_screen.dart';
import '../library/lorebooks_screen.dart';
import '../presets/presets_screen.dart';
import 'discover_browser_sheet.dart';
import 'discover_card.dart';

/// A catalogue entry's page — the character sheet, for a character that is not
/// yours yet.
///
/// It is the *same* page as [CharacterSheetScreen] in everything that shows: the
/// art at its own proportions with the name burned into it, the scrolling tag
/// band, the creator's notes rendered as they wrote them (HTML, CSS and images
/// included), and the definition behind folds whose greetings are drawn by the
/// real chat bubble. Two things differ, and only two: the catalogue's own numbers
/// sit between the tags and the notes, and the button downloads instead of
/// starting a chat.
///
/// The definition is fetched as the page opens, because that is also what a
/// download needs: by the time the button is pressed the work is usually done.
/// Until it lands the page shows everything the feed knew. When the site refuses
/// (JannyAI's card API is Cloudflare-guarded from some networks) it says what
/// happened and lets the button try again.
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
      // A card's own `character_book` rides along with it. Filing the character
      // and dropping its world info would look like a working download and
      // behave like a broken character — and the book is *attached*, so it is in
      // force in every chat with them and travels on if the card is exported
      // again.
      if (lorebook != null) {
        await state.addLorebook(lorebook);
        character.lorebookIds.add(lorebook.id);
      }
      await state.addCharacter(character);
      _savedCharacterId = character.id;
      message = lorebook == null
          ? '${character.displayName} added to Characters'
          : '${character.displayName} and its lorebook '
              '(${lorebook.entries.length} entries) added';
      open = () => _push(CharacterSheetScreen(characterId: character.id));
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
    final book = _payload?.lorebook;
    final notes = _notes();
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      floatingActionButton: _downloadButton(),
      // One CustomScrollView of slivers, exactly as the character sheet is built,
      // so the art can be the top of the page rather than sit under a title bar.
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            actions: [
              IconButton(
                tooltip: 'Open on ${widget.source.label}',
                icon: const Icon(Icons.open_in_new),
                onPressed: _openInBrowser,
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: _Portrait(item: item, character: character),
          ),
          SliverToBoxAdapter(child: TagBand(tags: _tags())),
          const SliverToBoxAdapter(child: SheetDivider()),
          SliverToBoxAdapter(
            child: _CatalogueBlock(
              item: item,
              source: widget.source,
              payload: _payload,
            ),
          ),
          const SliverToBoxAdapter(child: SheetDivider()),
          SliverToBoxAdapter(
            child: NotesBlock(notes: notes.text, label: notes.label),
          ),
          if (_loading) const SliverToBoxAdapter(child: _LoadingNote()),
          if (_error != null)
            SliverToBoxAdapter(
              child: _ErrorNote(
                message: _error!,
                onRetry: _retry,
                // A bot check has a real way through it; offer that instead of a
                // retry that will be refused the same way.
                onPassCheck:
                    _challenge != null && webViewSupported ? _passCheck : null,
              ),
            ),
          if (notes.text.trim().isNotEmpty && (character != null || book != null))
            const SliverToBoxAdapter(child: SheetDivider()),
          if (character != null)
            SliverToBoxAdapter(
              // Not interactive: the scenario picker writes onto a stored
              // character, and this one is still the catalogue's.
              child: DefinitionFolds(character: character, interactive: false),
            )
          else if (book != null)
            SliverToBoxAdapter(child: _BookFolds(book: book)),
          // Room for the download button to sit over nothing important.
          SliverToBoxAdapter(child: SizedBox(height: 120 + bottomInset)),
        ],
      ),
    );
  }

  /// The tags to band across the page: the card's own once it has arrived, since
  /// a fetched card usually carries more of them than the listing did.
  List<String> _tags() {
    final tags = _payload?.character?.tags ?? const <String>[];
    return tags.isNotEmpty ? tags : widget.item.tags;
  }

  /// The prose block under the numbers, and what to call it. A fetched card's
  /// creator notes when it has any; otherwise the listing's own blurb, which is
  /// what the site shows on its page and is not the creator's notes.
  ({String text, String label}) _notes() {
    final character = _payload?.character;
    if (character != null && character.creatorNotes.trim().isNotEmpty) {
      return (text: character.creatorNotes, label: 'Creator notes');
    }
    final book = _payload?.lorebook;
    if (character == null && book != null && book.description.trim().isNotEmpty) {
      return (text: book.description, label: 'About');
    }
    return (text: widget.item.description, label: 'About');
  }

  Widget _downloadButton() {
    if (_saved) {
      final id = _savedCharacterId;
      return FloatingActionButton.extended(
        onPressed: () {
          if (id != null) {
            _push(CharacterSheetScreen(characterId: id));
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
}

/// A lorebook's entries as folds, the same shell the definition uses. Only the
/// first few: the rest arrive with the download, and saying so is more honest
/// than a page that scrolls for a minute.
class _BookFolds extends StatelessWidget {
  const _BookFolds({required this.book});

  final Lorebook book;

  static String _title(LorebookEntry entry) {
    final name = entry.name.trim();
    if (name.isNotEmpty) return name;
    return entry.keys.isEmpty ? 'Entry' : entry.keys.join(', ');
  }

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final entry in book.entries.take(8))
            TextFold(title: _title(entry), body: entry.content),
          if (book.entries.length > 8)
            TextFold(
              title: 'And more',
              body: '${book.entries.length - 8} further entries download '
                  'with the book.',
            ),
        ],
      );
}

/// The art at its own proportions across the full width, with the name in the
/// lower-right over a fade — the character sheet's header, drawn from a listing.
///
/// The listing's largest image wins over the fetched card's own avatar: it is
/// the picture the catalogue publishes for exactly this purpose, and using it
/// throughout means the header does not swap out from under the reader halfway
/// through the fetch.
class _Portrait extends StatelessWidget {
  const _Portrait({required this.item, required this.character});

  final DiscoverItem item;
  final Character? character;

  String get _imageRef {
    final listed = item.bestImageUrl?.trim() ?? '';
    if (listed.isNotEmpty) return listed;
    return character?.avatar.trim() ?? '';
  }

  String get _meta => <String>[
        if (item.creator.trim().isNotEmpty) 'by ${item.creator.trim()}',
        if (item.nsfw) '18+',
      ].join(' · ');

  IconData get _icon => item.kind == DiscoverKind.character
      ? Icons.person_outline
      : Icons.menu_book_outlined;

  @override
  Widget build(BuildContext context) {
    final ref = _imageRef;
    // A lorebook, or a listing whose art never existed: a full-width empty
    // square is not a header, so it reads as a tile with the name under it.
    if (ref.isEmpty) {
      return _PlainHeader(name: item.name, meta: _meta, icon: _icon);
    }

    return NaturalImage(
      imageRef: ref,
      fallback: DiscoverImage(url: null, fallbackIcon: _icon),
      // Passed as the picture's own overlay rather than stacked around it, so a
      // capped (very tall) picture keeps its caption on the artwork instead of
      // in the empty margin beside it.
      overlay: IgnorePointer(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 40, 20, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(alpha: 0.62),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    item.name,
                    textAlign: TextAlign.right,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  if (_meta.isNotEmpty)
                    Text(
                      _meta,
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.white.withValues(alpha: 0.82),
                          ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The header for something with no art: a rounded tile, the name, the byline.
class _PlainHeader extends StatelessWidget {
  const _PlainHeader({
    required this.name,
    required this.meta,
    required this.icon,
  });

  final String name;
  final String meta;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Column(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: SizedBox(
              width: 140,
              height: 140,
              child: DiscoverImage(url: null, fallbackIcon: icon),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            name,
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
        ],
      ),
    );
  }
}

/// The one thing a catalogue entry has that a local character does not: where it
/// came from and what the site says about it. Flat and between two thin rules,
/// in the sheet's own idiom, rather than a card floating in the page.
class _CatalogueBlock extends StatelessWidget {
  const _CatalogueBlock({
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
    final tagline = item.tagline.trim();
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
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SheetLabel('From the catalogue'),
          if (tagline.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              tagline,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                  ),
            ),
          ],
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
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            // Expanded, not free-standing: on a 360dp phone this line is wider
            // than the space beside the spinner and would overflow.
            Expanded(
              child: Text(
                'Fetching the full definition…',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
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
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
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
