#ifndef AV_CONFERENCE_AUDIO_QUEUE_H
#define AV_CONFERENCE_AUDIO_QUEUE_H

#include <cstddef>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>

namespace tim2tox {

struct AVConferenceAudioFrame {
    std::string group_id;
    uint32_t conference_number = 0;
    uint32_t peer_number = 0;
    std::vector<int16_t> pcm;
    std::size_t sample_count = 0;
    uint8_t channels = 0;
    uint32_t sampling_rate = 0;
};

class AVConferenceAudioQueue {
public:
    void Enqueue(AVConferenceAudioFrame frame);
    std::vector<AVConferenceAudioFrame> Drain();
    void ClearGroup(std::string_view group_id);
    void ClearAll();

private:
    static constexpr std::size_t kMaxFrames = 64;

    std::mutex mutex_;
    std::deque<AVConferenceAudioFrame> frames_;
};

}  // namespace tim2tox

#endif
