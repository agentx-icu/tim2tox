import 'package:test/test.dart';
import 'package:tim2tox_dart/service/polling_event_ownership.dart';

void main() {
  group('Polling event ownership', () {
    test('shared service accepts registered test-instance events', () {
      expect(
        acceptsPollingEvent(
          serviceInstanceId: 0,
          eventInstanceId: 1,
          isKnownEventInstance: true,
        ),
        isTrue,
      );
      expect(
        acceptsPollingEvent(
          serviceInstanceId: 0,
          eventInstanceId: 2,
          isKnownEventInstance: true,
        ),
        isTrue,
      );
    });

    test('shared service rejects unknown event instances', () {
      expect(
        acceptsPollingEvent(
          serviceInstanceId: 0,
          eventInstanceId: 99,
          isKnownEventInstance: false,
        ),
        isFalse,
      );
    });

    test('nonzero service stays strict to its own instance', () {
      expect(
        acceptsPollingEvent(
          serviceInstanceId: 1,
          eventInstanceId: 1,
          isKnownEventInstance: true,
        ),
        isTrue,
      );
      expect(
        acceptsPollingEvent(
          serviceInstanceId: 1,
          eventInstanceId: 2,
          isKnownEventInstance: true,
        ),
        isFalse,
      );
    });

    test('nonzero service rejects foreign known events', () {
      expect(
        acceptsPollingEvent(
          serviceInstanceId: 2,
          eventInstanceId: 1,
          isKnownEventInstance: true,
        ),
        isFalse,
      );
    });
  });
}
