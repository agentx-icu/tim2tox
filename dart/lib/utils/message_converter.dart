// Message converter utility.
//
// Converts V2TimMessage -> ChatMessage for the binary-replacement path.
// The reverse direction lives on the Platform side as
// Tim2ToxSdkPlatformConverters.chatMessageToV2TimMessage (see
// dart/lib/sdk/tim2tox_sdk_platform_converters.dart) because the
// Platform version also takes forward-target user/group parameters
// used by the forward-message flow.
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
  static ChatMessage v2TimMessageToChatMessage(V2TimMessage v2Msg, String selfId) {
    // Determine media kind and extract content
    String text = '';
    String? filePath;
    String? fileName;
    String? mediaKind;
    
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
        break;
      case MessageElemType.V2TIM_ELEM_TYPE_CUSTOM:
        // Custom messages might have text in custom data
        text = v2Msg.customElem?.data ?? '';
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
    
    // Get timestamp (convert from seconds to milliseconds)
    final timestamp = v2Msg.timestamp != null
        ? DateTime.fromMillisecondsSinceEpoch(v2Msg.timestamp! * 1000)
        : DateTime.now();
    
    // Get sender ID
    final fromUserId = v2Msg.sender ?? v2Msg.userID ?? '';
    
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
      isPending: isPending,
      isReceived: isReceived,
      isRead: isRead,
      msgID: v2Msg.msgID,
    );
  }
}
