// Message converter utility.
//
// Converts V2TimMessage -> ChatMessage for the binary-replacement path.
// The reverse direction lives on the Platform side as
// Tim2ToxSdkPlatformConverters.chatMessageToV2TimMessage (see
// dart/lib/sdk/tim2tox_sdk_platform_converters.dart) because the
// Platform version also takes forward-target user/group parameters
// used by the forward-message flow.
import 'dart:convert';

import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_status.dart';
import '../models/chat_message.dart';

/// Message converter utility class.
class MessageConverter {
  /// Convert V2TimMessage to ChatMessage
  ///
  /// Extracts relevant fields from V2TimMessage and creates a ChatMessage.
  /// Handles different message types (text, image, video, audio, file).
  ///
  /// [receivedAt] is the live-delivery instant (defaults to now); see
  /// [timestampOf].
  static ChatMessage v2TimMessageToChatMessage(
      V2TimMessage v2Msg, String selfId,
      {DateTime? receivedAt}) {
    // Determine media kind and extract content
    String text = '';
    String? filePath;
    String? fileName;
    String? mediaKind;
    int? fileSize;

    // Extract text and file information based on element type
    switch (v2Msg.elemType) {
      case MessageElemType.V2TIM_ELEM_TYPE_TEXT:
        text = v2Msg.textElem?.text ?? '';
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_IMAGE:
        mediaKind = 'image';
        text = ''; // Images don't have text content
        filePath = v2Msg.imageElem?.path;
        // Try to get filename from path
        if (filePath != null && filePath.isNotEmpty) {
          fileName = filePath.split('/').last;
        }
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_VIDEO:
        mediaKind = 'video';
        text = '';
        filePath = v2Msg.videoElem?.videoPath;
        if (filePath != null && filePath.isNotEmpty) {
          fileName = filePath.split('/').last;
        }
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_SOUND:
        mediaKind = 'audio';
        text = '';
        filePath = v2Msg.soundElem?.path;
        if (filePath != null && filePath.isNotEmpty) {
          fileName = filePath.split('/').last;
        }
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_FILE:
        mediaKind = 'file';
        text = '';
        filePath = v2Msg.fileElem?.path;
        fileName = v2Msg.fileElem?.fileName;
        fileSize = v2Msg.fileElem?.fileSize;
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_CUSTOM:
        mediaKind = 'custom';
        text = v2Msg.customElem?.data ?? '';
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_FACE:
        final face = v2Msg.faceElem;
        text = '__face__:${jsonEncode({
              'index': face?.index ?? 0,
              'data': face?.data ?? '',
            })}';
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_LOCATION:
        final location = v2Msg.locationElem;
        text = '__location__:${jsonEncode({
              'desc': location?.desc ?? '',
              'longitude': location?.longitude ?? 0.0,
              'latitude': location?.latitude ?? 0.0,
            })}';
        break;
      default:
        // For other types, try to get text from textElem as fallback
        text = v2Msg.textElem?.text ?? '';
        break;
    }

    // Determine if message is from self
    final isSelf = v2Msg.isSelf ?? (v2Msg.sender == selfId);

    // Determine message status
    final isPending = v2Msg.status == MessageStatus.V2TIM_MSG_STATUS_SENDING;
    final isReceived = v2Msg.status == MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
    final isRead = v2Msg.isRead ?? false;

    final timestamp = timestampOf(v2Msg, receivedAt ?? DateTime.now());

    // Get sender ID
    final fromUserId = v2Msg.sender ?? v2Msg.userID ?? '';

    // GH-4: an inbound NGC group message carries toxcore's
    // Tox_Group_Message_Id in localCustomData. Stamp the same cross-path
    // alias the poll path derives from its `gtext:` header (both paths see the
    // sender's per-group public key), so the two copies dedupe EXACTLY and two
    // genuine identical messages ("ok", "ok") never collapse by content.
    final groupId = v2Msg.groupID;
    final toxGroupMsgId =
        toxGroupMsgIdFromLocalCustomData(v2Msg.localCustomData);
    final groupAlias = groupId != null &&
            groupId.isNotEmpty &&
            fromUserId.isNotEmpty &&
            toxGroupMsgId != null
        ? toxGroupMessageAlias(
            groupId: groupId,
            senderPk: fromUserId,
            pseudoMsgId: toxGroupMsgId,
          )
        : null;

    // Create ChatMessage
    return ChatMessage(
      text: text,
      fromUserId: fromUserId,
      isSelf: isSelf,
      timestamp: timestamp,
      groupId: v2Msg.groupID,
      filePath: filePath,
      fileName: fileName,
      mediaKind: mediaKind,
      fileSize: fileSize,
      isPending: isPending,
      isFailed: isSelf &&
          v2Msg.status == MessageStatus.V2TIM_MSG_STATUS_SEND_FAIL,
      isReceived: isReceived,
      isRead: isRead,
      msgID: v2Msg.msgID,
      cloudCustomData: v2Msg.cloudCustomData,
      contentKind:
          chatMessageContentKindFromLocalCustomData(v2Msg.localCustomData),
      altMsgIds: [if (groupAlias != null) groupAlias],
    );
  }

  /// Row timestamp for a V2TIM message. The V2TIM timestamp is whole SECONDS
  /// (the native layer stamps an inbound message with its receive second),
  /// while rows minted in Dart are millisecond-precise; truncating put every
  /// inbound row at `.000` and sorted it BEFORE a self row sent later in the
  /// same second. When [receivedAt] falls inside (or just past) that second,
  /// i.e. this is the live delivery, use the receive instant clamped into the
  /// native second so the stamp never contradicts it. Anything else (a
  /// replay, an old message) keeps the exact native second.
  static DateTime timestampOf(V2TimMessage v2Msg, DateTime receivedAt) {
    final seconds = v2Msg.timestamp;
    if (seconds == null || seconds <= 0) return receivedAt;
    final baseMs = seconds * 1000;
    final receivedMs = receivedAt.millisecondsSinceEpoch;
    if (receivedMs >= baseMs && receivedMs < baseMs + 2000) {
      return DateTime.fromMillisecondsSinceEpoch(
        receivedMs < baseMs + 999 ? receivedMs : baseMs + 999,
      );
    }
    return DateTime.fromMillisecondsSinceEpoch(baseMs);
  }
}
