#include "source/AVConferenceAudioQueue.h"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace {

using tim2tox::AVConferenceAudioFrame;
using tim2tox::AVConferenceAudioQueue;

AVConferenceAudioFrame MakeFrame(std::string group_id, int marker) {
    AVConferenceAudioFrame frame;
    frame.group_id = std::move(group_id);
    frame.conference_number = 11;
    frame.peer_number = 22;
    frame.pcm = {static_cast<int16_t>(marker),
                 static_cast<int16_t>(marker + 1000)};
    frame.sample_count = frame.pcm.size();
    frame.channels = 1;
    frame.sampling_rate = 48000;
    return frame;
}

int MarkerOf(const AVConferenceAudioFrame& frame) {
    EXPECT_FALSE(frame.pcm.empty());
    return frame.pcm.empty() ? -1 : frame.pcm.front();
}

TEST(AVConferenceAudioQueueTest, DrainsNewest64FramesInOriginalOrder) {
    AVConferenceAudioQueue queue;

    for (int marker = 0; marker < 80; ++marker) {
        queue.Enqueue(MakeFrame("group-a", marker));
    }

    const std::vector<AVConferenceAudioFrame> drained = queue.Drain();

    ASSERT_EQ(drained.size(), 64U);
    for (std::size_t index = 0; index < drained.size(); ++index) {
        EXPECT_EQ(MarkerOf(drained[index]), static_cast<int>(index) + 16);
        EXPECT_EQ(drained[index].group_id, "group-a");
    }
    EXPECT_TRUE(queue.Drain().empty());
}

TEST(AVConferenceAudioQueueTest, ClearGroupRemovesOnlyThatGroupsFrames) {
    AVConferenceAudioQueue queue;
    queue.Enqueue(MakeFrame("group-a", 1));
    queue.Enqueue(MakeFrame("group-b", 2));
    queue.Enqueue(MakeFrame("group-a", 3));

    queue.ClearGroup("group-a");
    const std::vector<AVConferenceAudioFrame> drained = queue.Drain();

    ASSERT_EQ(drained.size(), 1U);
    EXPECT_EQ(drained.front().group_id, "group-b");
    EXPECT_EQ(MarkerOf(drained.front()), 2);
}

TEST(AVConferenceAudioQueueTest, ClearAllRemovesEveryPendingFrame) {
    AVConferenceAudioQueue queue;
    queue.Enqueue(MakeFrame("group-a", 1));
    queue.Enqueue(MakeFrame("group-b", 2));

    queue.ClearAll();

    EXPECT_TRUE(queue.Drain().empty());
}

}
