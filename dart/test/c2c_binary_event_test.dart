import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim2tox_dart/service/ffi_chat_service.dart';

const _sender =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

String _repeat(String value, int count) => List.filled(count, value).join();

String _event(String payload, {int route = 3, String sender = _sender}) {
  final hex = <int>[route, ...utf8.encode(payload)]
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return 'c2cbin:$sender:$hex';
}

void main() {
  group('c2cbin atomic event parser', () {
    for (final entry in <(int, String)>[
      (
        0,
        '{"type":"third-party","text":"advanced-listener owned"}',
      ),
      (1, '{"type":"receipt","msgID":"m1","receiptType":"read"}'),
      (
        2,
        '{"type":"reaction","msgID":"m1","reactionID":"wave",'
            '"action":"add"}',
      ),
      (3, '{"type":"third-party","text":"visible custom"}'),
      (
        4,
        '{"type":"msgidbind","msgID":"m1","textHash":"ab12",'
            '"sender":"$_sender"}',
      ),
    ]) {
      test('extracts route ${entry.$1} before decoding JSON payload', () {
        final parsed = FfiChatService.parseC2cBinaryEvent(
          _event(entry.$2, route: entry.$1),
        );

        expect(parsed?.sender, _sender);
        expect(parsed?.route, entry.$1);
        expect(parsed?.payload, entry.$2);
      });
    }

    test('rejects route bytes outside the internal 0..4 contract', () {
      expect(
        FfiChatService.parseC2cBinaryEvent(_event('{}', route: 5)),
        isNull,
      );
    });

    test('rejects malformed UTF-8 after a valid route byte', () {
      expect(
        FfiChatService.parseC2cBinaryEvent('c2cbin:$_sender:03ff'),
        isNull,
      );
    });

    test('rejects malformed hex', () {
      expect(
        FfiChatService.parseC2cBinaryEvent('c2cbin:$_sender:00zz'),
        isNull,
      );
    });

    test('rejects odd-length hex', () {
      expect(
        FfiChatService.parseC2cBinaryEvent('c2cbin:$_sender:0'),
        isNull,
      );
    });

    test('rejects sender values outside the 64-hex public-key contract', () {
      for (final sender in <String>[
        '',
        _repeat('A', 63),
        _repeat('A', 65),
        '${_repeat('A', 63)}Z',
      ]) {
        expect(
          FfiChatService.parseC2cBinaryEvent(_event('{}', sender: sender)),
          isNull,
          reason: 'sender=$sender',
        );
      }
    });
  });

  test('C2C controls have no pollCustom queue dependency', () {
    final source = File('lib/service/ffi_chat_service.dart').readAsStringSync();

    expect(source, isNot(contains('_lastCustomSender')));
    expect(source, isNot(contains('_lastCustomGroupID')));
    expect(source, isNot(contains('.pollCustom(')));
    expect(source, contains('sourceInstanceId: sourceInstanceId'));
  });

  test('receipt and reaction sends use distinct typed native controls', () {
    final source = File('lib/service/ffi_chat_service.dart').readAsStringSync();
    final receiptStart = source.indexOf('Future<void> _sendReceipt(');
    final receiptEnd =
        source.indexOf('Future<void> _handleReceipt(', receiptStart);
    final reactionStart = source.indexOf('Future<void> sendReaction(');
    final reactionEnd = source.indexOf(
      'String _groupOfflineQueueKey(',
      reactionStart,
    );
    expect(receiptStart, greaterThanOrEqualTo(0));
    expect(receiptEnd, greaterThan(receiptStart));
    expect(reactionStart, greaterThanOrEqualTo(0));
    expect(reactionEnd, greaterThan(reactionStart));

    final receipt = source.substring(receiptStart, receiptEnd);
    final reaction = source.substring(reactionStart, reactionEnd);
    expect(receipt, contains('.sendC2CControlNative('));
    expect(receipt, matches(RegExp(r'jsonBytes\.length,\s*1\s*\)')));
    expect(receipt, contains("'sender': _wireSelfSender()"));
    expect(receipt, isNot(contains('.sendC2CCustomNative(')));
    expect(reaction, contains('.sendC2CControlNative('));
    expect(reaction, matches(RegExp(r'jsonBytes\.length,\s*2\s*\)')));
    expect(reaction, contains("'sender': _wireSelfSender()"));
    expect(reaction, isNot(contains('.sendC2CCustomNative(')));
  });

  test('C2C receipts hash-echo the content correlator', () {
    final source = File('lib/service/ffi_chat_service.dart').readAsStringSync();
    final receiptStart = source.indexOf('Future<void> _sendReceipt(');
    final receiptEnd =
        source.indexOf('Future<void> _handleReceipt(', receiptStart);
    final receipt = source.substring(receiptStart, receiptEnd);
    // The wire receipt carries `bind:<sha256(text)>` in the free-form msgID
    // field (4-key schema unchanged; old peers unaffected), and the sender
    // field is the real Tox identity, never the login alias.
    expect(receipt, contains("'bind:"));
    expect(receipt, contains('_c2cTextHash(echoText)'));
    expect(receipt, contains("'msgID': wireMsgID"));
    expect(receipt, contains("'sender': _wireSelfSender()"));
    expect(receipt, isNot(contains('normalizeToxId(_selfId)')));

    final handleStart = source.indexOf('Future<void> _handleReceipt(');
    final handleEnd = source.indexOf('List<String> getMessageReaders(');
    final handle = source.substring(handleStart, handleEnd);
    // Sender-side: hash correlators match by content, oldest-unflagged
    // first; plain ids keep the exact legacy match.
    expect(handle, contains("msgID.startsWith('bind:')"));
    expect(handle, contains('_c2cTextHash(msg.text) == hashWanted'));
  });
}
