import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/embedding.dart';

void main() {
  group('EmbeddingConfig', () {
    test('round-trips through JSON with all fields', () {
      const config = EmbeddingConfig(
        enabled: true,
        providerId: 'p1',
        model: 'text-embedding-3-large',
        chatRecallDefault: true,
        loreActivation: true,
        insert: 5,
        queryMessages: 3,
        protect: 8,
        threshold: 0.4,
        messageChunkSize: 500,
        docChunkSize: 6000,
        docOverlapPercent: 15,
        depth: 3,
        template: 'Memory:\n{{text}}',
        docTemplate: 'Docs:\n{{text}}',
      );
      final restored = EmbeddingConfig.fromJson(config.toJson());
      expect(restored.enabled, true);
      expect(restored.providerId, 'p1');
      expect(restored.model, 'text-embedding-3-large');
      expect(restored.chatRecallDefault, true);
      expect(restored.loreActivation, true);
      expect(restored.insert, 5);
      expect(restored.queryMessages, 3);
      expect(restored.protect, 8);
      expect(restored.threshold, 0.4);
      expect(restored.messageChunkSize, 500);
      expect(restored.docChunkSize, 6000);
      expect(restored.docOverlapPercent, 15);
      expect(restored.depth, 3);
      expect(restored.template, 'Memory:\n{{text}}');
      expect(restored.docTemplate, 'Docs:\n{{text}}');
    });

    test('defaults are the SillyTavern Vector Storage values', () {
      const c = EmbeddingConfig();
      expect(c.enabled, false);
      expect(c.model, kDefaultEmbeddingModel);
      expect(c.insert, 3);
      expect(c.queryMessages, 2);
      expect(c.protect, 5);
      expect(c.threshold, 0.25);
      expect(c.messageChunkSize, 400);
      expect(c.depth, 2);
      expect(c.isReady, false);
    });

    test('isReady needs enabled AND a provider', () {
      expect(const EmbeddingConfig(enabled: true).isReady, false);
      expect(
        const EmbeddingConfig(enabled: true, providerId: 'p').isReady,
        true,
      );
      expect(const EmbeddingConfig(providerId: 'p').isReady, false);
    });

    test('copyWith can clear the provider', () {
      const c = EmbeddingConfig(providerId: 'p');
      expect(c.copyWith(clearProvider: true).providerId, isNull);
      expect(c.copyWith(model: 'm').providerId, 'p');
    });
  });

  group('EmbeddingDocument', () {
    test('round-trips through JSON', () {
      final doc = EmbeddingDocument(
        id: 'd1',
        name: 'Notes',
        source: DocSource.url,
        origin: 'https://example.org',
        chunkCount: 12,
        model: 'text-embedding-3-small',
      );
      final restored = EmbeddingDocument.fromJson(doc.toJson());
      expect(restored.id, 'd1');
      expect(restored.name, 'Notes');
      expect(restored.source, DocSource.url);
      expect(restored.origin, 'https://example.org');
      expect(restored.chunkCount, 12);
      expect(restored.isIndexed, true);
    });
  });

  group('VectorRecord', () {
    test('round-trips a Float32 vector through base64 JSON', () {
      final record = VectorRecord(
        key: 'k',
        text: 'hello',
        vector: Float32List.fromList(const [0.5, -0.25, 1.0, 0.0]),
      );
      final restored = VectorRecord.fromJson(record.toJson());
      expect(restored.key, 'k');
      expect(restored.text, 'hello');
      expect(restored.vector, [0.5, -0.25, 1.0, 0.0]);
    });
  });
}
