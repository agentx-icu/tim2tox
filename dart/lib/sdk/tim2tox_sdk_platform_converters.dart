/// Type conversion helpers for Tim2ToxSdkPlatform
///
/// This file contains extension methods and helper functions for converting
/// between internal models (ChatMessage, FakeConversation, etc.) and V2Tim models.

import 'dart:convert';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_message.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_conversation.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_info.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_friend_application.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_user_full_info.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_elem_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/message_status.dart';
import 'package:tencent_cloud_chat_sdk/enum/conversation_type.dart';
import 'package:tencent_cloud_chat_sdk/enum/friend_application_type_enum.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_text_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_image_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_image.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_file_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_sound_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_video_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_custom_elem.dart';
import 'package:tencent_cloud_chat_sdk/models/v2_tim_merger_elem.dart';
import 'package:tencent_cloud_chat_sdk/enum/image_types.dart';
import 'dart:io';
import '../models/chat_message.dart';
import '../models/fake_models.dart';
import '../service/ffi_chat_service.dart';
import '../interfaces/extended_preferences_service.dart';
import 'tim2tox_sdk_platform.dart';

/// Extension methods for Tim2ToxSdkPlatform to handle type conversions
extension Tim2ToxSdkPlatformConverters on Tim2ToxSdkPlatform {
  /// Parse merger message from text
  /// Returns (mergerJson, compatibleText, hasMerger) if message contains merger markers
  ({String mergerJson, String compatibleText, bool hasMerger})
      parseMergerMessage(String text) {
    const mergerStartMarker = '[MERGER_START]';
    const mergerEndMarker = '[MERGER_END]';

    final startPos = text.indexOf(mergerStartMarker);
    final endPos = text.indexOf(mergerEndMarker);

    if (startPos == -1 || endPos == -1 || endPos <= startPos) {
      return (mergerJson: '', compatibleText: text, hasMerger: false);
    }

    // Extract merger JSON
    final jsonStart = startPos + mergerStartMarker.length;
    final jsonLength = endPos - jsonStart;
    final mergerJson = text.substring(jsonStart, jsonStart + jsonLength);

    // Extract compatible text (after MERGER_END marker)
    final textStart = endPos + mergerEndMarker.length;
    String compatibleText = '';
    if (textStart < text.length) {
      // Skip possible newlines after marker
      int actualStart = textStart;
      while (actualStart < text.length &&
          (text[actualStart] == '\n' || text[actualStart] == '\r')) {
        actualStart++;
      }
      compatibleText = text.substring(actualStart);
    }

    return (
      mergerJson: mergerJson,
      compatibleText: compatibleText,
      hasMerger: true
    );
  }

  /// Parse reply message from text
  /// Returns (replyJson, actualText, hasReply) if message contains reply markers
  /// Format: [REPLY_START]...JSON...[REPLY_END]\n实际文本内容
  ({String replyJson, String actualText, bool hasReply}) parseReplyMessage(
      String text) {
    const replyStartMarker = '[REPLY_START]';
    const replyEndMarker = '[REPLY_END]';

    final startPos = text.indexOf(replyStartMarker);
    final endPos = text.indexOf(replyEndMarker);

    if (startPos == -1 || endPos == -1 || endPos <= startPos) {
      return (replyJson: '', actualText: text, hasReply: false);
    }

    // Extract reply JSON
    final jsonStart = startPos + replyStartMarker.length;
    final jsonLength = endPos - jsonStart;
    final replyJson = text.substring(jsonStart, jsonStart + jsonLength);

    // Extract actual text (after REPLY_END marker)
    final textStart = endPos + replyEndMarker.length;
    String actualText = '';
    if (textStart < text.length) {
      // Skip possible newlines after marker
      int actualStart = textStart;
      while (actualStart < text.length &&
          (text[actualStart] == '\n' || text[actualStart] == '\r')) {
        actualStart++;
      }
      actualText = text.substring(actualStart);
    }

    return (replyJson: replyJson, actualText: actualText, hasReply: true);
  }

  /// Convert ChatMessage to V2TimMessage
  V2TimMessage chatMessageToV2TimMessage(
    ChatMessage chatMsg,
    String selfId, {
    String? forwardTargetUserID,
    String? forwardTargetGroupID,
  }) {
    // First, check for merger message or reply message in text (only for text messages)
    bool isTextMessage = chatMsg.mediaKind == null || chatMsg.mediaKind == '';

    // Check for merger message first (priority)
    if (isTextMessage) {
      final mergerResult = parseMergerMessage(chatMsg.text);
      if (mergerResult.hasMerger) {
        try {
          // Parse merger JSON
          final mergerData =
              json.decode(mergerResult.mergerJson) as Map<String, dynamic>;
          final title = mergerData['title'] as String? ?? '';
          final abstractList = (mergerData['abstractList'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [];
          final messageIDList = (mergerData['messageIDList'] as List<dynamic>?)
                  ?.map((e) => e.toString())
                  .toList() ??
              [];

          // Create merger message
          final msg =
              V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_MERGER);
          final msgID = chatMsg.msgID ??
              '${chatMsg.timestamp.millisecondsSinceEpoch}_${chatMsg.fromUserId}';
          msg.msgID = msgID;
          // CRITICAL: Also set id to msgID to ensure proper matching with UIKit messages
          msg.id = msgID;
          msg.timestamp = chatMsg.timestamp.millisecondsSinceEpoch ~/ 1000;
          msg.sender = chatMsg.fromUserId;
          // Use forward target if available, otherwise use default logic
          msg.userID = forwardTargetUserID ??
              (chatMsg.groupId == null ? chatMsg.fromUserId : null);
          msg.groupID = forwardTargetGroupID ?? chatMsg.groupId;
          msg.isSelf = chatMsg.isSelf;
          // Set message status - CRITICAL: For sent messages, default to SEND_SUCC unless explicitly pending or failed
          if (chatMsg.isPending) {
            msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
          } else if (chatMsg.isSelf) {
            // For self-sent messages, default to SEND_SUCC unless explicitly marked as failed
            msg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
          } else {
            // For received messages, always SEND_SUCC
            msg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
          }

          msg.mergerElem = V2TimMergerElem(
            title: title,
            abstractList: abstractList,
            compatibleText: mergerResult.compatibleText,
          );
          // Add to elemList so it appears in message_elem_array
          msg.elemList.add(msg.mergerElem!);

          // Set cloudCustomData with messageIDList
          if (messageIDList.isNotEmpty) {
            final cloudCustomDataMap = {
              'mergerMessageIDs': messageIDList,
            };
            msg.cloudCustomData = json.encode(cloudCustomDataMap);
          }

          return msg;
        } catch (e) {
          // If parsing fails, fall through to normal text message handling
          print('Failed to parse merger message: $e');
        }
      }

      // Check for reply message
      final replyResult = parseReplyMessage(chatMsg.text);
      if (replyResult.hasReply) {
        try {
          // Parse reply JSON
          final replyData =
              json.decode(replyResult.replyJson) as Map<String, dynamic>;

          // Create text message with reply
          final msg =
              V2TimMessage(elemType: MessageElemType.V2TIM_ELEM_TYPE_TEXT);
          final msgID = chatMsg.msgID ??
              '${chatMsg.timestamp.millisecondsSinceEpoch}_${chatMsg.fromUserId}';
          msg.msgID = msgID;
          // CRITICAL: Also set id to msgID to ensure proper matching with UIKit messages
          msg.id = msgID;
          msg.timestamp = chatMsg.timestamp.millisecondsSinceEpoch ~/ 1000;
          msg.sender = chatMsg.fromUserId;
          // Use forward target if available, otherwise use default logic
          msg.userID = forwardTargetUserID ??
              (chatMsg.groupId == null ? chatMsg.fromUserId : null);
          msg.groupID = forwardTargetGroupID ?? chatMsg.groupId;
          msg.isSelf = chatMsg.isSelf;
          // Set message status - CRITICAL: For sent messages, default to SEND_SUCC unless explicitly pending or failed
          if (chatMsg.isPending) {
            msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
          } else if (chatMsg.isSelf) {
            // For self-sent messages, default to SEND_SUCC unless explicitly marked as failed
            msg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
          } else {
            // For received messages, always SEND_SUCC
            msg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
          }

          // Set text element with actual text
          msg.textElem = V2TimTextElem(text: replyResult.actualText);
          // Add to elemList so it appears in message_elem_array
          msg.elemList.add(msg.textElem!);

          // Set cloudCustomData with messageReference
          final cloudCustomDataMap = {
            'messageReference': replyData,
          };
          msg.cloudCustomData = json.encode(cloudCustomDataMap);

          return msg;
        } catch (e) {
          // If parsing fails, fall through to normal text message handling
          print('Failed to parse reply message: $e');
        }
      }
    }

    // Determine element type for non-text or normal text messages
    int elemType = MessageElemType.V2TIM_ELEM_TYPE_TEXT;
    if (chatMsg.mediaKind == 'image') {
      elemType = MessageElemType.V2TIM_ELEM_TYPE_IMAGE;
    } else if (chatMsg.mediaKind == 'video') {
      elemType = MessageElemType.V2TIM_ELEM_TYPE_VIDEO;
    } else if (chatMsg.mediaKind == 'audio') {
      elemType = MessageElemType.V2TIM_ELEM_TYPE_SOUND;
    } else if (chatMsg.mediaKind == 'file') {
      elemType = MessageElemType.V2TIM_ELEM_TYPE_FILE;
    } else if (chatMsg.mediaKind == 'custom') {
      elemType = MessageElemType.V2TIM_ELEM_TYPE_CUSTOM;
    }

    final msg = V2TimMessage(elemType: elemType);
    final msgID = chatMsg.msgID ??
        '${chatMsg.timestamp.millisecondsSinceEpoch}_${chatMsg.fromUserId}';
    msg.msgID = msgID;
    // CRITICAL: Also set id to msgID to ensure proper matching with UIKit messages
    // UIKit messages may have id (temporary ID) while FFI messages have msgID (actual ID)
    // Setting both ensures we can match messages correctly and prevent duplicates
    msg.id = msgID;
    msg.timestamp = chatMsg.timestamp.millisecondsSinceEpoch ~/ 1000;
    msg.sender = chatMsg.fromUserId;
    // Use forward target if available, otherwise use default logic
    // IMPORTANT: For received messages (isSelf=false), fromUserId is the sender's ID (peer's ID), so userID should be fromUserId
    // For sent messages (isSelf=true), fromUserId is our own ID, so we need forwardTargetUserID to get the peer's ID
    // If forwardTargetUserID is not available for sent messages, we'll need to find it from the message context
    if (forwardTargetUserID != null || forwardTargetGroupID != null) {
      msg.userID = forwardTargetUserID;
      msg.groupID = forwardTargetGroupID;
    } else {
      // No forward target provided - use default logic
      if (chatMsg.groupId != null) {
        // Group message: use groupId
        msg.groupID = chatMsg.groupId;
        msg.userID = null;
      } else {
        // C2C message: for received messages, fromUserId is the peer's ID; for sent messages, we need to find the peer's ID
        if (chatMsg.isSelf) {
          // For sent messages, we can't determine the peer's ID from ChatMessage alone
          // This should be handled by the caller providing forwardTargetUserID
          // If forwardTargetUserID is not provided, we'll leave userID as null
          // The caller (in _setupMessageListener or getHistory) should find it from history or set it from conversation context
          msg.userID = null; // Will be fixed by caller
        } else {
          // For received messages, fromUserId is the sender's ID (peer's ID)
          msg.userID = chatMsg.fromUserId;
        }
      }
    }
    msg.isSelf = chatMsg.isSelf;
    // Set message status - CRITICAL: For sent messages, default to SEND_SUCC unless explicitly pending or failed
    // The logic should be:
    // - If isPending=true: SENDING (message is still being sent)
    // - If isPending=false and isSelf=true: SEND_SUCC (sent message, default to success unless explicitly failed)
    // - If isPending=false and isSelf=false: SEND_SUCC (received message, always success)
    // - SEND_FAIL should only be set when explicitly known to have failed (e.g., from FFI error or timeout)
    if (chatMsg.isPending) {
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SENDING;
    } else if (chatMsg.isSelf) {
      // For self-sent messages, default to SEND_SUCC unless explicitly marked as failed
      // isReceived=true means message was received by peer, so definitely SEND_SUCC
      // isReceived=false means we don't know yet, but since isPending=false, message was sent, so default to SEND_SUCC
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
    } else {
      // For received messages, always SEND_SUCC
      msg.status = MessageStatus.V2TIM_MSG_STATUS_SEND_SUCC;
    }

    // Set element type based on mediaKind
    // NOTE: elemType is already set when creating V2TimMessage, but we set it again here for clarity
    // This is redundant but harmless
    if (chatMsg.mediaKind == 'image') {
      // msg.elemType is already set to MessageElemType.V2TIM_ELEM_TYPE_IMAGE
      if (chatMsg.filePath != null) {
        // Generate UUID from msgID for download identification
        final imageUuid = msgID.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
        int? fileSize;
        try {
          final file = File(chatMsg.filePath!);
          if (file.existsSync()) {
            fileSize = file.lengthSync();
          }
        } catch (e) {
          // Ignore file size errors
        }

        // Create image list with both thumb and origin images
        // UIKit may request either THUMB (1) or ORIGIN (0), so we need both
        // This is required for downloadMessage to work properly
        final imageList = [
          V2TimImage(
            uuid: imageUuid,
            type: V2TIM_IMAGE_TYPE.V2TIM_IMAGE_TYPE_THUMB,
            size: fileSize,
            url: chatMsg.filePath, // Use local path as URL for Tox protocol
            localUrl: chatMsg.filePath,
          ),
          V2TimImage(
            uuid: imageUuid,
            type: V2TIM_IMAGE_TYPE.V2TIM_IMAGE_TYPE_ORIGIN,
            size: fileSize,
            url: chatMsg.filePath, // Use local path as URL for Tox protocol
            localUrl: chatMsg.filePath,
          ),
        ];

        msg.imageElem = V2TimImageElem(
          path: chatMsg.filePath,
          imageList: imageList,
        );
        // Add to elemList so it appears in message_elem_array
        msg.elemList.add(msg.imageElem!);
      }
    } else if (chatMsg.mediaKind == 'video') {
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_VIDEO;
      if (chatMsg.filePath != null) {
        msg.videoElem = V2TimVideoElem(
          videoPath: chatMsg.filePath,
        );
        // Add to elemList so it appears in message_elem_array
        msg.elemList.add(msg.videoElem!);
      }
    } else if (chatMsg.mediaKind == 'audio') {
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_SOUND;
      if (chatMsg.filePath != null) {
        msg.soundElem = V2TimSoundElem(
          path: chatMsg.filePath,
        );
        // Add to elemList so it appears in message_elem_array
        msg.elemList.add(msg.soundElem!);
      }
    } else if (chatMsg.mediaKind == 'file') {
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_FILE;
      if (chatMsg.filePath != null) {
        // Generate UUID from msgID for download identification
        final fileUuid = msgID.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
        int? fileSize;
        try {
          final file = File(chatMsg.filePath!);
          if (file.existsSync()) {
            fileSize = file.lengthSync();
          }
        } catch (e) {
          // Ignore file size errors
        }

        msg.fileElem = V2TimFileElem(
          path: chatMsg.filePath,
          fileName: chatMsg.fileName,
          UUID: fileUuid, // Required for downloadMessage
          url: chatMsg.filePath, // Use local path as URL for Tox protocol
          fileSize: fileSize,
          localUrl: chatMsg.filePath,
        );
        // Add to elemList so it appears in message_elem_array
        msg.elemList.add(msg.fileElem!);
      }
    } else if (chatMsg.mediaKind == 'call_record') {
      // Call record: text contains CallingMessage-compatible JSON
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_CUSTOM;
      msg.customElem = V2TimCustomElem(
        data: chatMsg.text,
        desc: '',
        extension: '',
      );
      msg.elemList.add(msg.customElem!);
    } else if (chatMsg.mediaKind == 'custom') {
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_CUSTOM;
      msg.customElem = V2TimCustomElem(
        data: chatMsg.text,
        desc: '',
        extension: '',
      );
      msg.elemList.add(msg.customElem!);
    } else {
      // Default to text message
      msg.elemType = MessageElemType.V2TIM_ELEM_TYPE_TEXT;
      msg.textElem = V2TimTextElem(text: chatMsg.text);
      // Add to elemList so it appears in message_elem_array
      msg.elemList.add(msg.textElem!);
    }

    return msg;
  }

  /// Convert FakeConversation to V2TimConversation
  Future<V2TimConversation> fakeConversationToV2TimConversation(
      FakeConversation fakeConv) async {
    final conv = V2TimConversation(conversationID: fakeConv.conversationID);
    conv.type = fakeConv.isGroup
        ? ConversationType.V2TIM_GROUP
        : ConversationType.V2TIM_C2C;

    if (fakeConv.isGroup) {
      conv.groupID = fakeConv.conversationID.replaceFirst('group_', '');
    } else {
      conv.userID = fakeConv.conversationID.replaceFirst('c2c_', '');
    }

    conv.showName = fakeConv.title;
    conv.faceUrl = fakeConv.faceUrl;
    conv.unreadCount = fakeConv.unreadCount;
    conv.isPinned = fakeConv.isPinned;

    final peerId = fakeConv.isGroup
        ? fakeConv.conversationID.replaceFirst('group_', '')
        : fakeConv.conversationID.replaceFirst('c2c_', '');

    // recvOpt is the per-peer DND state (0 = receive, 2 = mute). UIKit reads
    // it back from V2TimConversation, so a stale 0 here makes the DND toggle
    // appear to reset on every conversation refresh. Pull from prefs when
    // available (only C2C currently — group DND has its own pathway and
    // isn't routed through this prefs key shape).
    if (!fakeConv.isGroup) {
      final prefs = preferencesService ?? ffiService.preferencesService;
      conv.recvOpt =
          await prefs?.getC2CReceiveMessageOpt(peerId, ffiService.selfId) ?? 0;
    } else {
      conv.recvOpt = 0;
    }

    // Fallback faceUrl from prefs when not set so conversation list/header show correct avatar
    if (conv.faceUrl == null || conv.faceUrl!.isEmpty) {
      final prefs = preferencesService ?? ffiService.preferencesService;
      conv.faceUrl = fakeConv.isGroup
          ? await prefs?.getGroupAvatar(peerId)
          : await prefs?.getFriendAvatarPath(peerId);
    }

    // Fallback showName from prefs when not set so conversation list/header show correct nickname
    if (!fakeConv.isGroup &&
        (conv.showName == null || conv.showName!.isEmpty)) {
      final prefs = preferencesService ?? ffiService.preferencesService;
      final nick = await prefs?.getFriendNickname(peerId);
      if (nick != null && nick.isNotEmpty) {
        conv.showName = nick;
      }
    }

    // Get last message from FfiChatService
    final lastMsg = ffiService.lastMessages[peerId];
    if (lastMsg != null) {
      conv.lastMessage = chatMessageToV2TimMessage(
        lastMsg,
        ffiService.selfId,
        forwardTargetUserID: fakeConv.isGroup ? null : peerId,
        forwardTargetGroupID: fakeConv.isGroup ? peerId : null,
      );
      final baseTimestamp = lastMsg.timestamp.millisecondsSinceEpoch;
      if (fakeConv.isPinned) {
        // Pinned conversations: use very large number (Int64.max - timestamp)
        conv.orderkey = (9223372036854775807 - baseTimestamp).toInt();
      } else {
        conv.orderkey = baseTimestamp;
      }
    } else {
      // No last message, use current timestamp
      final baseTimestamp = DateTime.now().millisecondsSinceEpoch;
      if (fakeConv.isPinned) {
        conv.orderkey = (9223372036854775807 - baseTimestamp).toInt();
      } else {
        conv.orderkey = baseTimestamp;
      }
    }

    return conv;
  }

  /// Convert FakeUser to V2TimFriendInfo
  Future<V2TimFriendInfo> fakeUserToV2TimFriendInfo(FakeUser fakeUser) async {
    final friendInfo = V2TimFriendInfo(userID: fakeUser.userID);

    // Get user profile
    final userProfile = V2TimUserFullInfo(userID: fakeUser.userID);
    userProfile.nickName = fakeUser.nickName;
    userProfile.faceUrl = fakeUser.faceUrl;
    // Get avatar path from Prefs if faceUrl is null
    final prefs = preferencesService ?? ffiService.preferencesService;
    if (userProfile.faceUrl == null || userProfile.faceUrl!.isEmpty) {
      userProfile.faceUrl = await prefs?.getFriendAvatarPath(fakeUser.userID);
    }

    friendInfo.userProfile = userProfile;

    // Backfill the user-edited alias so the contact list, search results, and
    // chat headers all see the remark stored via setFriendInfo. Without this
    // the alias only lives in the editing UI's local state and disappears on
    // reload. Reads from the same per-account scope the host adapter writes
    // to, so multi-account does not bleed remarks across accounts.
    final remark = await prefs?.getFriendRemark(fakeUser.userID);
    if (remark != null && remark.isNotEmpty) {
      friendInfo.friendRemark = remark;
    }

    return friendInfo;
  }

  /// Convert FakeFriendApplication to V2TimFriendApplication
  V2TimFriendApplication fakeFriendApplicationToV2TimFriendApplication(
      FakeFriendApplication fakeApp) {
    return V2TimFriendApplication(
      userID: fakeApp.userID,
      addWording: fakeApp.wording,
      type: FriendApplicationTypeEnum
          .V2TIM_FRIEND_APPLICATION_COME_IN.index, // Default to incoming
    );
  }
}
