import 'dart:convert';

const _facePrefix = '__face__:';
const _locationPrefix = '__location__:';
const _customPrefix = '__custom__:';
const _revokePrefix = '__revoke__:';

sealed class TextControlEnvelope {
  const TextControlEnvelope(this.originalText);

  final String originalText;

  bool get shouldSwallow => false;
}

final class PlainTextEnvelope extends TextControlEnvelope {
  const PlainTextEnvelope(super.originalText);
}

final class FaceTextEnvelope extends TextControlEnvelope {
  const FaceTextEnvelope({
    required String originalText,
    required this.rawPayload,
    required this.payload,
  }) : super(originalText);

  final String rawPayload;
  final Map<String, Object?> payload;
}

final class LocationTextEnvelope extends TextControlEnvelope {
  const LocationTextEnvelope({
    required String originalText,
    required this.rawPayload,
    required this.payload,
  }) : super(originalText);

  final String rawPayload;
  final Map<String, Object?> payload;
}

final class CustomTextEnvelope extends TextControlEnvelope {
  const CustomTextEnvelope({
    required String originalText,
    required this.rawPayload,
  }) : super(originalText);

  final String rawPayload;
}

final class RevokeTextEnvelope extends TextControlEnvelope {
  const RevokeTextEnvelope({
    required String originalText,
    required this.rawPayload,
    required this.payload,
  }) : super(originalText);

  final String rawPayload;
  final Map<String, Object?>? payload;

  @override
  bool get shouldSwallow => true;
}

TextControlEnvelope parseTextControlEnvelope(String text) {
  if (text.startsWith(_revokePrefix)) {
    final rawPayload = text.substring(_revokePrefix.length);
    return RevokeTextEnvelope(
      originalText: text,
      rawPayload: rawPayload,
      payload: _decodeJsonObject(rawPayload),
    );
  }

  if (text.startsWith(_facePrefix)) {
    final rawPayload = text.substring(_facePrefix.length);
    final payload = _decodeJsonObject(rawPayload);
    if (payload != null &&
        payload['index'] is int &&
        payload['data'] is String) {
      return FaceTextEnvelope(
        originalText: text,
        rawPayload: rawPayload,
        payload: payload,
      );
    }
    return PlainTextEnvelope(text);
  }

  if (text.startsWith(_locationPrefix)) {
    final rawPayload = text.substring(_locationPrefix.length);
    final payload = _decodeJsonObject(rawPayload);
    if (payload != null &&
        payload['desc'] is String &&
        payload['longitude'] is num &&
        payload['latitude'] is num) {
      return LocationTextEnvelope(
        originalText: text,
        rawPayload: rawPayload,
        payload: payload,
      );
    }
    return PlainTextEnvelope(text);
  }

  if (text.startsWith(_customPrefix)) {
    return CustomTextEnvelope(
      originalText: text,
      rawPayload: text.substring(_customPrefix.length),
    );
  }

  return PlainTextEnvelope(text);
}

Map<String, Object?>? _decodeJsonObject(String rawPayload) {
  try {
    final decoded = jsonDecode(rawPayload);
    if (decoded is! Map<Object?, Object?>) {
      return null;
    }
    final normalized = <String, Object?>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      if (key is! String) {
        return null;
      }
      normalized[key] = entry.value;
    }
    return Map<String, Object?>.unmodifiable(normalized);
  } on FormatException {
    return null;
  }
}
