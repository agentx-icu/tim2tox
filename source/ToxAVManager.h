#ifndef TOXAV_MANAGER_H
#define TOXAV_MANAGER_H

#include <cstdint>
#include <memory>
#include <mutex>
#include <functional>
#include "toxav/toxav.h"

class V2TIMManagerImpl;

class ToxAVManager {
public:
    // 构造函数（现在是 public，支持多实例）
    ToxAVManager();
    
    // 禁止拷贝和赋值
    ToxAVManager(const ToxAVManager&) = delete;
    ToxAVManager& operator=(const ToxAVManager&) = delete;
    
    // 向后兼容：获取默认实例（单例模式）
    static ToxAVManager& getInstance();
    
    // 初始化 toxav（传入 manager_impl 避免在内部再次调用 GetCurrentInstance，防止多实例竞态/段错误）
    void initialize(V2TIMManagerImpl* manager_impl);

    // Retain the legacy conference receive context for disable/enable cycles.
    // The owning V2TIMManagerImpl outlives this manager and is cleared on shutdown.
    bool setConferenceAudioCallbackContext(
        toxav_audio_data_cb* conference_audio_callback,
        V2TIMManagerImpl* manager_impl);
    
    // 关闭 toxav
    void shutdown();
    
    // 迭代 toxav（需要在主循环中调用）
    void iterate();
    
    // 开始通话
    bool startCall(uint32_t friend_number, uint32_t audio_bit_rate, uint32_t video_bit_rate);
    
    // 结束通话
    bool endCall(uint32_t friend_number);
    
    // 接听通话
    bool answerCall(uint32_t friend_number, uint32_t audio_bit_rate, uint32_t video_bit_rate);
    
    // 静音/取消静音
    bool muteAudio(uint32_t friend_number, bool mute);
    
    // 关闭/开启视频
    bool muteVideo(uint32_t friend_number, bool mute);
    
    // 发送音频帧
    bool sendAudioFrame(uint32_t friend_number, const int16_t* pcm, size_t sample_count, 
                       uint8_t channels, uint32_t sampling_rate);
    bool sendConferenceAudioFrame(uint32_t conference_number, const int16_t* pcm,
                                  size_t sample_count, uint8_t channels,
                                  uint32_t sampling_rate);
    bool enableConferenceAudio(uint32_t conference_number);
    bool disableConferenceAudio(uint32_t conference_number);
    bool isConferenceAudioEnabled(uint32_t conference_number) const;
    
    // 发送视频帧
    bool sendVideoFrame(uint32_t friend_number, uint16_t width, uint16_t height,
                       const uint8_t* y, const uint8_t* u, const uint8_t* v);
    
    // 设置音频比特率
    bool setAudioBitRate(uint32_t friend_number, uint32_t audio_bit_rate);
    
    // 设置视频比特率
    bool setVideoBitRate(uint32_t friend_number, uint32_t video_bit_rate);
    
    // 回调类型定义
    using CallCallback = std::function<void(uint32_t friend_number, bool audio_enabled, bool video_enabled)>;
    using CallStateCallback = std::function<void(uint32_t friend_number, uint32_t state)>;
    using AudioBitrateCallback = std::function<void(uint32_t friend_number, uint32_t audio_bit_rate)>;
    using VideoBitrateCallback = std::function<void(uint32_t friend_number, uint32_t video_bit_rate)>;
    using AudioReceiveFrameCallback = std::function<void(uint32_t friend_number, const int16_t* pcm,
                                                         size_t sample_count, uint8_t channels, uint32_t sampling_rate)>;
    using VideoReceiveFrameCallback = std::function<void(uint32_t friend_number, uint16_t width, uint16_t height,
                                                         const uint8_t* y, const uint8_t* u, const uint8_t* v)>;
    
    // 设置回调
    void setCallCallback(CallCallback cb);
    void setCallStateCallback(CallStateCallback cb);
    void setAudioBitrateCallback(AudioBitrateCallback cb);
    void setVideoBitrateCallback(VideoBitrateCallback cb);
    void setAudioReceiveFrameCallback(AudioReceiveFrameCallback cb);
    void setVideoReceiveFrameCallback(VideoReceiveFrameCallback cb);
    
    // 获取 ToxAV 实例（用于高级操作）
    ToxAV* getToxAV() const;

    // 供 unique_ptr 等使用的删除接口（析构函数为 private 时，外部通过此接口释放）
    static void Destroy(ToxAVManager* p);

private:
    // 析构函数
    ~ToxAVManager();
    
    // 自定义删除器（functor 避免取静态成员函数地址导致的潜在问题）
    struct ToxAVDeleter {
        void operator()(ToxAV* p) const;
    };
    
    // ToxAV 实例
    std::unique_ptr<ToxAV, ToxAVDeleter> toxav_;
    Tox* tox_ = nullptr;
    V2TIMManagerImpl* manager_impl_ = nullptr;
    toxav_audio_data_cb* conference_audio_callback_ = nullptr;
    
    // 互斥锁
    mutable std::mutex mutex_;
    
    // 回调函数
    CallCallback call_cb_;
    CallStateCallback call_state_cb_;
    AudioBitrateCallback audio_bitrate_cb_;
    VideoBitrateCallback video_bitrate_cb_;
    AudioReceiveFrameCallback audio_receive_frame_cb_;
    VideoReceiveFrameCallback video_receive_frame_cb_;
};

#endif // TOXAV_MANAGER_H
