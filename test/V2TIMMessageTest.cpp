#include <gtest/gtest.h>
#include "V2TIMMessage.h"
#include "V2TIMString.h"
#include <cstring>
#include <string>
#include <vector>

// Test V2TIMMessage creation and basic properties
TEST(V2TIMMessageTest, BasicProperties) {
    // Create a message
    V2TIMMessage msg;
    
    // Test default properties
    EXPECT_EQ(msg.seq, 0);
    EXPECT_TRUE(msg.msgID.Empty());
    EXPECT_TRUE(msg.sender.Empty());
    EXPECT_TRUE(msg.groupID.Empty());
    EXPECT_TRUE(msg.userID.Empty());
    EXPECT_EQ(msg.elemList.Size(), 0);
    EXPECT_FALSE(msg.isSelf);
    EXPECT_FALSE(msg.IsRead());
    EXPECT_FALSE(msg.IsPeerRead());
    EXPECT_FALSE(msg.needReadReceipt);
    EXPECT_FALSE(msg.isBroadcastMessage);
    EXPECT_EQ(msg.status, static_cast<V2TIMMessageStatus>(0));
    
    // Set some properties
    msg.msgID = "test_message_id";
    msg.sender = "test_sender";
    msg.groupID = "test_group";
    msg.userID = "test_user";
    msg.timestamp = 1234567890;
    msg.isSelf = true;
    msg.status = V2TIM_MSG_STATUS_SEND_SUCC;
    
    // Test updated properties
    EXPECT_EQ(msg.msgID, "test_message_id");
    EXPECT_EQ(msg.sender, "test_sender");
    EXPECT_EQ(msg.groupID, "test_group");
    EXPECT_EQ(msg.userID, "test_user");
    EXPECT_EQ(msg.timestamp, 1234567890);
    EXPECT_TRUE(msg.isSelf);
    EXPECT_EQ(msg.status, V2TIM_MSG_STATUS_SEND_SUCC);
}

// Test V2TIMMessage with text element
TEST(V2TIMMessageTest, TextMessage) {
    V2TIMMessage msg;
    
    // Create a text element
    V2TIMTextElem* textElem = new V2TIMTextElem();
    textElem->elemType = V2TIM_ELEM_TYPE_TEXT;
    textElem->text = "Hello, this is a test message";
    
    // Add to message
    msg.elemList.PushBack(textElem);
    
    // Test element properties
    EXPECT_EQ(msg.elemList.Size(), 1);
    EXPECT_NE(msg.elemList[0], nullptr);
    EXPECT_EQ(msg.elemList[0]->elemType, V2TIM_ELEM_TYPE_TEXT);
    
    // Cast to proper type and check content
    V2TIMTextElem* retrievedElem = static_cast<V2TIMTextElem*>(msg.elemList[0]);
    EXPECT_EQ(retrievedElem->text, "Hello, this is a test message");
}

// Test V2TIMMessage with custom element
TEST(V2TIMMessageTest, CustomMessage) {
    V2TIMMessage msg;
    
    // Create custom data
    const std::string customData = "Custom data content";
    const std::vector<uint8_t> customBytes(customData.begin(), customData.end());
    V2TIMBuffer buffer(customBytes.data(), customBytes.size());
    
    // Create a custom element
    V2TIMCustomElem* customElem = new V2TIMCustomElem();
    customElem->elemType = V2TIM_ELEM_TYPE_CUSTOM;
    customElem->data = buffer;
    customElem->desc = "Test custom message";
    customElem->extension = "ext data";
    
    // Add to message
    msg.elemList.PushBack(customElem);
    
    // Test element properties
    EXPECT_EQ(msg.elemList.Size(), 1);
    EXPECT_NE(msg.elemList[0], nullptr);
    EXPECT_EQ(msg.elemList[0]->elemType, V2TIM_ELEM_TYPE_CUSTOM);
    
    // Cast to proper type and check content
    V2TIMCustomElem* retrievedElem = static_cast<V2TIMCustomElem*>(msg.elemList[0]);
    EXPECT_EQ(retrievedElem->data.Size(), customBytes.size());
    EXPECT_EQ(std::memcmp(retrievedElem->data.Data(), customBytes.data(), customBytes.size()), 0);
    EXPECT_EQ(retrievedElem->desc, "Test custom message");
    EXPECT_EQ(retrievedElem->extension, "ext data");
}

// Test V2TIMMessage copy constructor and assignment operator
TEST(V2TIMMessageTest, CopyAndAssignment) {
    V2TIMMessage msg1;
    msg1.msgID = "test_id";
    msg1.sender = "test_sender";
    msg1.timestamp = 1234567890;
    
    // Add a text element
    V2TIMTextElem* textElem = new V2TIMTextElem();
    textElem->elemType = V2TIM_ELEM_TYPE_TEXT;
    textElem->text = "Test message";
    msg1.elemList.PushBack(textElem);
    
    // Test copy constructor
    V2TIMMessage msg2(msg1);
    EXPECT_EQ(msg2.msgID, msg1.msgID);
    EXPECT_EQ(msg2.sender, msg1.sender);
    EXPECT_EQ(msg2.timestamp, msg1.timestamp);
    EXPECT_EQ(msg2.elemList.Size(), msg1.elemList.Size());
    
    V2TIMTextElem* copiedElem = static_cast<V2TIMTextElem*>(msg2.elemList[0]);
    EXPECT_EQ(copiedElem->text, "Test message");
    
    // Test assignment operator
    V2TIMMessage msg3;
    msg3 = msg1;
    EXPECT_EQ(msg3.msgID, msg1.msgID);
    EXPECT_EQ(msg3.sender, msg1.sender);
    EXPECT_EQ(msg3.timestamp, msg1.timestamp);
    EXPECT_EQ(msg3.elemList.Size(), msg1.elemList.Size());
    
    V2TIMTextElem* assignedElem = static_cast<V2TIMTextElem*>(msg3.elemList[0]);
    EXPECT_EQ(assignedElem->text, "Test message");
}
