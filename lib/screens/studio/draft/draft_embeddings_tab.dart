import 'package:flutter/material.dart';

import '../../../models/studio.dart';
import '../../../services/studio/studio_controller.dart';
import '../../library/embeddings_config_screen.dart';
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
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return ListView(
      key: const PageStorageKey('draft-embeddings'),
      padding: draftListPadding(context, top: 20),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kDraftCardInset),
          child: Material(
            color: ready
                ? scheme.primaryContainer
                : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(kDraftOuterRadius),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    ready ? Icons.hub : Icons.hub_outlined,
                    size: 28,
                    color: ready
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ready ? 'Embeddings are on' : 'Embeddings are off',
                        style: theme.textTheme.titleLarge?.copyWith(
                          color: ready
                              ? scheme.onPrimaryContainer
                              : scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        ready
                            ? 'Documents are indexed with '
                                  '${config.model.trim().isEmpty ? 'the chosen model' : config.model} '
                                  'when you apply, and recalled by meaning in chats.'
                            : 'Documents stay in the draft but are left out '
                                  'when you apply. Turn embeddings on to index them.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.45,
                          color: ready
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonal(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const EmbeddingsConfigScreen(),
                        ),
                      ),
                      child: const Text('Set up'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        DraftSectionLabel('To index', count: ws.documents.length),
        if (ws.documents.isEmpty)
          const DraftEmpty(
            icon: Icons.hub_outlined,
            text:
                'Nothing to index yet. Documents the Studio or you write '
                'appear here.',
          )
        else
          DraftCard(
            children: [
              for (final doc in ws.documents)
                _IndexRow(
                  key: ValueKey('draft-index-${doc.id}'),
                  doc: doc,
                  tokens: state.estimateTokens(doc.text),
                  chunkSize: config.docChunkSize,
                  status: _statusOf(controller, doc),
                  muted: muted,
                ),
            ],
          ),
      ],
    );
  }

  static _IndexStatus _statusOf(
    StudioController controller,
    StudioDocument doc,
  ) {
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
    final chunks = chunkSize <= 0
        ? 1
        : (tokens / chunkSize).ceil().clamp(1, 1 << 20);
    final dot = switch (status) {
      _IndexStatus.indexed => scheme.primary,
      _IndexStatus.onApply => scheme.tertiary,
      _IndexStatus.leftOut => scheme.outline,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      child: Row(
        children: [
          Icon(Icons.description_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  doc.name.trim().isEmpty ? 'Untitled document' : doc.name,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        '${status.label} · about $chunks '
                        'chunk${chunks == 1 ? '' : 's'}',
                        style: muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
