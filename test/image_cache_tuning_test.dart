import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/image_cache_tuning.dart';

const int _mib = 1024 * 1024;

void main() {
  test('keeps Flutter default bytes as the low-memory floor', () {
    final budget = imageCacheBudget(physicalMemoryBytes: 256 * _mib);

    expect(budget.maximumSize, 2000);
    expect(budget.maximumSizeBytes, 100 * _mib);
  });

  test('uses one fifth of memory between the bounds', () {
    final budget = imageCacheBudget(physicalMemoryBytes: 768 * _mib);

    expect(budget.maximumSizeBytes, (768 * _mib * 0.20).round());
  });

  test('caps the decoded bitmap budget at 256 MiB', () {
    final budget = imageCacheBudget(physicalMemoryBytes: 8 * 1024 * _mib);

    expect(budget.maximumSizeBytes, 256 * _mib);
  });

  test('unknown memory falls back to the safe floor', () {
    final budget = imageCacheBudget(physicalMemoryBytes: 0);

    expect(budget.maximumSizeBytes, 100 * _mib);
  });
}
