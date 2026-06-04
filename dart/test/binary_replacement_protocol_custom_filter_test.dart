// Guards the binary-replacement history hook's internal-protocol custom
// filter: tim2tox's OWN receipt/reaction packets must be dropped (they were
// rendering as raw JSON chat bubbles), while a peer app's legitimate custom
// message — even one that reuses a `type` like "reaction" — must SURVIVE.
// Regression target: the product-screenshot pipeline found receipts in chat.

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/utils/binary_replacement_history_hook.dart';

void main() {
  bool isProtocol(String? data) =>
      BinaryReplacementHistoryHook.isInternalProtocolCustomData(data);

  group('drops tim2tox internal protocol customs', () {
    test('full receipt packet (type+receiptType+msgID)', () {
      expect(
        isProtocol(
          '{"type":"receipt","msgID":"m_1","receiptType":"received",'
          '"sender":"AABB"}',
        ),
        isTrue,
      );
    });

    test('read receipt with groupID', () {
      expect(
        isProtocol(
          '{"type":"receipt","msgID":"m_2","receiptType":"read",'
          '"sender":"AABB","groupID":"g1"}',
        ),
        isTrue,
      );
    });

    test('full reaction packet (type+reactionID+action+msgID)', () {
      expect(
        isProtocol(
          '{"type":"reaction","msgID":"m_3","reactionID":"👍",'
          '"action":"add","sender":"AABB"}',
        ),
        isTrue,
      );
    });
  });

  group('preserves real / ambiguous content', () {
    test('plain text-shaped custom is kept', () {
      expect(isProtocol('{"type":"text","text":"hi"}'), isFalse);
    });

    test('peer custom reusing type=reaction WITHOUT the protocol fields', () {
      // A third-party app could legitimately send this as display content;
      // it lacks reactionID/action/msgID so it must NOT be dropped.
      expect(isProtocol('{"type":"reaction","emoji":"👍"}'), isFalse);
    });

    test('peer custom reusing type=receipt without receiptType', () {
      expect(isProtocol('{"type":"receipt","note":"see you"}'), isFalse);
    });

    test('reaction missing only the action field is kept', () {
      expect(
        isProtocol('{"type":"reaction","msgID":"m","reactionID":"x"}'),
        isFalse,
      );
    });

    test('av_call signaling envelope is NOT protocol (call-record row)', () {
      expect(
        isProtocol('{"data":"{\\"businessID\\":\\"av_call\\"}","type":"x"}'),
        isFalse,
      );
    });

    test('empty / null / non-json are kept (treated as content)', () {
      expect(isProtocol(null), isFalse);
      expect(isProtocol(''), isFalse);
      expect(isProtocol('not json'), isFalse);
      expect(isProtocol('[1,2,3]'), isFalse);
    });
  });
}
