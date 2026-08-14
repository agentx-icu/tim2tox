#include "AVConferenceAudioQueue.h"

#include <algorithm>
#include <utility>

namespace tim2tox {

void AVConferenceAudioQueue::Enqueue(AVConferenceAudioFrame frame) {
    std::lock_guard<std::mutex> lock(mutex_);
    frames_.push_back(std::move(frame));
    while (frames_.size() > kMaxFrames) {
        frames_.pop_front();
    }
}

std::vector<AVConferenceAudioFrame> AVConferenceAudioQueue::Drain() {
    std::vector<AVConferenceAudioFrame> drained_frames;
    std::lock_guard<std::mutex> lock(mutex_);
    drained_frames.reserve(frames_.size());
    while (!frames_.empty()) {
        drained_frames.push_back(std::move(frames_.front()));
        frames_.pop_front();
    }
    return drained_frames;
}

void AVConferenceAudioQueue::ClearGroup(std::string_view group_id) {
    std::lock_guard<std::mutex> lock(mutex_);
    frames_.erase(std::remove_if(frames_.begin(), frames_.end(),
                                 [group_id](const AVConferenceAudioFrame& frame) {
                                     return frame.group_id == group_id;
                                 }),
                  frames_.end());
}

void AVConferenceAudioQueue::ClearAll() {
    std::lock_guard<std::mutex> lock(mutex_);
    frames_.clear();
}

}  // namespace tim2tox
