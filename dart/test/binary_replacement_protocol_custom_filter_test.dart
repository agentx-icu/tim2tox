// Guards the binary-replacement history hook's internal-protocol custom
// filter: tim2tox's OWN receipt/reaction packets must be dropped (they were
// rendering as raw JSON chat bubbles), while a peer app's legitimate custom
// message — even one that reuses a `type` like "reaction" — must SURVIVE.
// Regression target: the product-screenshot pipeline found receipts in chat.

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/models/chat_message.dart';
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

    test('ACTION JSON resembling a receipt but carrying peer content is kept',
        () {
      expect(
        isProtocol(
          '{"type":"receipt","msgID":"m_4","receiptType":"displayed",'
          '"sender":"AABB","text":"waves"}',
        ),
        isFalse,
      );
    });

    test('valid receipt fields plus peer content are kept', () {
      expect(
        isProtocol(
          '{"type":"receipt","msgID":"m_4","receiptType":"read",'
          '"sender":"AABB","text":"waves"}',
        ),
        isFalse,
      );
    });

    test('ACTION JSON resembling a reaction with an unknown action is kept',
        () {
      expect(
        isProtocol(
          '{"type":"reaction","msgID":"m_5","reactionID":"wave",'
          '"action":"animate","sender":"AABB","text":"waves"}',
        ),
        isFalse,
      );
    });

    test('valid reaction fields plus peer content are kept', () {
      expect(
        isProtocol(
          '{"type":"reaction","msgID":"m_5","reactionID":"wave",'
          '"action":"add","sender":"AABB","text":"waves"}',
        ),
        isFalse,
      );
    });

    test('legacy receipt without sender context is not hidden from history',
        () {
      expect(
        isProtocol(
          '{"type":"receipt","msgID":"m_6","receiptType":"received"}',
        ),
        isFalse,
      );
    });

    test('legacy reaction without sender context is not hidden from history',
        () {
      expect(
        isProtocol(
          '{"type":"reaction","msgID":"m_7","reactionID":"wave",'
          '"action":"add"}',
        ),
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

  group('history-aware legacy control consumption', () {
    const peerId = 'AABB';
    final history = [
      ChatMessage(
        text: 'existing',
        fromUserId: 'SELF',
        isSelf: true,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1),
        msgID: 'known-message',
      ),
    ];

    test('consumes exact control only when referenced message exists', () {
      expect(
        BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData(
          data: '{"type":"receipt","msgID":"known-message",'
              '"receiptType":"read","sender":"$peerId"}',
          callbackSender: peerId,
          conversationId: peerId,
          history: history,
        ),
        isTrue,
      );
    });

    test('preserves exact control when referenced message is absent', () {
      expect(
        BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData(
          data: '{"type":"receipt","msgID":"missing-message",'
              '"receiptType":"read","sender":"$peerId"}',
          callbackSender: peerId,
          conversationId: peerId,
          history: history,
        ),
        isFalse,
      );
    });

    // Group receipts are authorized by the NGC ENVELOPE identity: the gaction
    // envelope sender is the toxcore-authenticated PER-GROUP key while the
    // payload sender carries the long-term id, so the strict payload==envelope
    // binding would reject every legitimate group receipt. senderBound: false
    // is passed ONLY for gaction+receipt (see _tryConsumeLegacyActionControl).
    test('senderBound=false consumes a receipt whose payload sender differs',
        () {
      expect(
        BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData(
          data: '{"type":"receipt","msgID":"known-message",'
              '"receiptType":"read","sender":"LONGTERM_ID_OF_READER"}',
          callbackSender: 'PER_GROUP_KEY_OF_READER',
          conversationId: 'g1',
          history: history,
          senderBound: false,
        ),
        isTrue,
      );
    });

    test('senderBound=false still requires the referenced message to exist',
        () {
      expect(
        BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData(
          data: '{"type":"receipt","msgID":"missing-message",'
              '"receiptType":"read","sender":"LONGTERM_ID_OF_READER"}',
          callbackSender: 'PER_GROUP_KEY_OF_READER',
          conversationId: 'g1',
          history: history,
          senderBound: false,
        ),
        isFalse,
      );
    });

    test('default stays strictly sender-bound (C2C/reactions unchanged)', () {
      expect(
        BinaryReplacementHistoryHook.shouldConsumeInternalProtocolCustomData(
          data: '{"type":"receipt","msgID":"known-message",'
              '"receiptType":"read","sender":"SOMEONE_ELSE"}',
          callbackSender: peerId,
          conversationId: peerId,
          history: history,
        ),
        isFalse,
      );
    });
  });
}
