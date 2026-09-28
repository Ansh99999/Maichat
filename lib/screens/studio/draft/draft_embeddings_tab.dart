import 'package:flutter/material.dart';

import '../../../models/studio.dart';
import '../../../services/studio/studio_controller.dart';
import '../../library/embeddings_config_screen.dart';
import 'draft_header.dart';
import 'draft_widgets.dart';

/// What applying the draft will put into the embeddings library, and whether it
/// can: the embeddings set-up as it stands, then each document with the state
/// it is in — already indexed, indexed on apply, or left out because
/// embeddings are off.
class DraftEmbeddingsTab extends StatelessWidget {
  const DraftEmbeddingsTab({super.key, required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final ws = controller.session.workspace;
    final state = controller.state;
    final config = state.embeddingConfig;
    final ready = state.embeddingReady;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return ListView(
      key: const PageStorageKey('draft-embeddings'),
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        DraftHeader(character: ws.character),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Material(
            color: ready ? scheme.primaryContainer : scheme.errorContainer,
            borderRadius: BorderRadius.circular(28),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              child: Row(
                children: [
                  Icon(
                    ready ? Icons.hub : Icons.hub_outlined,
                    color: ready ? scheme.onPrimaryContainer : scheme.onErrorContainer,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ready ? 'Embeddings are on' : 'Embeddings are off',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: ready
                                ? scheme.onPrimaryContainer
                                : scheme.onErrorContainer,
                          ),
                        ),
                        Text(
                          ready
                              ? 'Documents are indexed with '
                                  '${config.model.trim().isEmpty ? 'the chosen model' : config.model} '
                                  'when you apply, and recalled by meaning in chats.'
                              : 'Documents stay in the draft but are left out '
                                  'when you apply. Turn embeddings on to index them.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: ready
                                ? scheme.onPrimaryContainer
                                : scheme.onErrorContainer,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const EmbeddingsConfigScreen(),
                      ),
                    ),
                    child: const Text('Set up'),
                  ),
                ],
              ),
            ),
          ),
        ),
        DraftSectionLabel('To index · ${ws.documents.length}'),
        if (ws.documents.isEmpty)
          const DraftEmpty(
            icon: Icons.hub_outlined,
            text: 'Nothing to index yet. Documents the Studio or you write '
                'appear here.',
          )
        else
          DraftCard(children: [
            for (final doc in ws.documents)
              _IndexRow(
                key: ValueKey('draft-index-${doc.id}'),
                doc: doc,
                tokens: state.estimateTokens(doc.text),
                chunkSize: config.docChunkSize,
                status: _statusOf(controller, doc),
                muted: muted,
              ),
          ]),
      ],
    );
  }

  static _IndexStatus _statusOf(StudioController controller, StudioDocument doc) {
    final state = controller.state;
    if (doc.libraryId != null && state.documentById(doc.libraryId) != null) {
      return _IndexStatus.indexed;
    }
    return state.embeddingReady ? _IndexStatus.onApply : _IndexStatus.leftOut;
  }
}

enum _IndexStatus {
  indexed('In your library'),
  onApply('Indexed on apply'),
  leftOut('Left out');

  const _IndexStatus(this.label);
  final String label;
}

class _IndexRow extends StatelessWidget {
  const _IndexRow({
    super.key,
    required this.doc,
    required this.tokens,
    required this.chunkSize,
    required this.status,
    required this.muted,
  });

  final StudioDocument doc;
  final int tokens;
  final int chunkSize;
  final _IndexStatus status;
  final TextStyle? muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final chunks = chunkSize <= 0 ? 1 : (tokens / chunkSize).ceil().clamp(1, 1 << 20);
    final (bg, fg) = switch (status) {
      _IndexStatus.indexed => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _IndexStatus.onApply => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      _IndexStatus.leftOut => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Icon(Icons.description_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(doc.name.trim().isEmpty ? 'Untitled document' : doc.name,
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text('$tokens tok · about $chunks chunk${chunks == 1 ? '' : 's'}',
                    style: muted),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(status.label,
                style: theme.textTheme.labelSmall?.copyWith(color: fg)),
          ),
        ],
      ),
    );
  }
}
