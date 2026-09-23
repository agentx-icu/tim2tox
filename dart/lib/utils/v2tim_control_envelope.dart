import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_custom_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_face_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_location_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';

import 'control_message_envelope.dart';

/// Give [msg] the structured element a `__face__:` / `__location__:` /
/// `__custom__:` text envelope stands for, and set the matching elemType.
///
/// The ONE place that turns a wire envelope into a V2Tim element: the history
/// converter (`chatMessageToV2TimMessage`) and the native fan-out
/// ([applyInboundControlEnvelope]) both go through it, so a sticker renders the
/// same whether it arrives live or is reloaded. Returns false (and leaves [msg]
/// untouched) for plain text and for `__revoke__:`, which is a command, not
/// content. [first] puts the element at the head of `elemList` (the element a
/// V2TimMessage renders) instead of appending it.
bool attachControlEnvelopeElem(
  V2TimMessage msg,
  TextControlEnvelope envelope, {
  bool first = false,
}) {
  final Object elem;
  switch (envelope) {
    case FaceTextEnvelope(:final payload):
      final face = V2TimFaceElem(
        index: payload['index'] as int?,
        data: payload['data'] as String?,
      );
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_FACE;
      msg.faceElem = face;
      elem = face;
    case LocationTextEnvelope(:final payload):
      final location = V2TimLocationElem(
        desc: payload['desc'] as String?,
        longitude: (payload['longitude'] as num).toDouble(),
        latitude: (payload['latitude'] as num).toDouble(),
      );
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_LOCATION;
      msg.locationElem = location;
      elem = location;
    case CustomTextEnvelope(:final rawPayload):
      final custom = V2TimCustomElem(data: rawPayload, desc: '', extension: '');
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_CUSTOM;
      msg.customElem = custom;
      elem = custom;
    case PlainTextEnvelope() || RevokeTextEnvelope():
      return false;
  }
  if (first) {
    msg.elemList.insert(0, elem);
  } else {
    msg.elemList.add(elem);
  }
  return true;
}

/// Apply the text-control-envelope contract to a message that did NOT come
/// through the history converter — the native `ReceiveNewMessage` fan-out.
///
/// Returns false when the message must not be shown to any listener (a
/// `__revoke__:` command: the binary-replacement history hook applies it).
/// For face/location/custom envelopes the raw text element is replaced in
/// place by the structured element, exactly as the converter renders it on
/// reload. Plain text is left alone.
bool applyInboundControlEnvelope(V2TimMessage msg) {
  final textElem = msg.textElem;
  final text = textElem?.text ?? '';
  if (!text.startsWith('__')) return true;
  final envelope = parseTextControlEnvelope(text);
  if (envelope.shouldSwallow) return false;
  if (envelope is PlainTextEnvelope) return true;
  msg.textElem = null;
  msg.elemList.removeWhere((e) => identical(e, textElem));
  attachControlEnvelopeElem(msg, envelope, first: true);
  return true;
}
