import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/update_service.dart';

void main() {
  test('isNewer compares the semver core, ignoring build/pre-release', () {
    expect(UpdateService.isNewer('1.6.5', '1.6.4'), isTrue);
    expect(UpdateService.isNewer('1.7.0', '1.6.9'), isTrue);
    expect(UpdateService.isNewer('2.0.0', '1.9.9'), isTrue);
    expect(UpdateService.isNewer('1.6.5+12', '1.6.4'), isTrue);

    expect(UpdateService.isNewer('1.6.4', '1.6.4'), isFalse);
    expect(UpdateService.isNewer('1.6.3', '1.6.4'), isFalse);
    expect(UpdateService.isNewer('1.6.4+9', '1.6.4+8'), isFalse);
  });
}
