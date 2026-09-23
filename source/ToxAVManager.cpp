#include "ToxAVManager.h"
#include "ToxManager.h"
#include "V2TIMManagerImpl.h"
#include "V2TIMLog.h"
#include "toxav/toxav.h"
#include <stdexcept>

// 向后兼容：默认实例（单例模式）
static ToxAVManager* g_default_toxav_instance = nullptr;
static std::mutex g_default_toxav_instance_mutex;

ToxAVManager& ToxAVManager::getInstance() {
    std::lock_guard<std::mutex> lock(g_default_toxav_instance_mutex);
    if (!g_default_toxav_instance) {
        g_default_toxav_instance = new ToxAVManager();
    }
    return *g_default_toxav_instance;
}

// 构造函数（现在是 public，支持多实例）
ToxAVManager::ToxAVManager() : toxav_(nullptr, ToxAVDeleter{}) {}

// 析构函数
ToxAVManager::~ToxAVManager() {
    shutdown();
}

void ToxAVManager::Destroy(ToxAVManager* p) {
    delete p;
}

// 自定义删除器实现
void ToxAVManager::ToxAVDeleter::operator()(ToxAV* toxav) const {
    if (toxav) toxav_kill(toxav);
}

// 初始化实现：使用调用方传入的 manager_impl，避免内部再次调用 GetCurrentInstance() 导致多实例竞态或段错误
void ToxAVManager::initialize(V2TIMManagerImpl* manager_impl) {
    // Common case (every AV conference create/join calls this): already
    // initialized. Answer it under the SHARED lock — an exclusive request while
    // ToxAV callbacks may be running could stall them behind the writer.
    {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        if (toxav_) {
            if (manager_impl_ == manager_impl) {
                V2TIMLog::getInstance().Info(
                    "[ToxAVManager] ToxAV instance already initialized for this owner");
                return;
            }
            V2TIMLog::getInstance().Error(
                "[ToxAVManager] ToxAV instance belongs to a different V2TIMManagerImpl");
            throw std::runtime_error(
                "ToxAV instance belongs to a different V2TIMManagerImpl");
        }
    }
    // toxav_new() registers its lossy-packet handlers through toxcore's
    // private, UNLOCKED setters while event_thread_ may be inside
    // tox_iterate(); hold ToxManager's iterate lock across it (taken BEFORE
    // mutex_, see the lock order in ToxAVManager.h). av_iterate_mutex_ is not
    // needed: iterate() does nothing while toxav_ is null.
    std::unique_lock<std::mutex> iterate_lock;
    if (manager_impl && manager_impl->GetToxManager()) {
        iterate_lock = manager_impl->GetToxManager()->lockIterate();
    }
    std::unique_lock<std::shared_mutex> lock(mutex_);
    V2TIMLog::getInstance().Info("[ToxAVManager] initialize() called");
    if (toxav_) {
        if (manager_impl_ == manager_impl) {
            V2TIMLog::getInstance().Info(
                "[ToxAVManager] ToxAV instance already initialized for this owner");
            return;
        }
        V2TIMLog::getInstance().Error(
            "[ToxAVManager] ToxAV instance belongs to a different V2TIMManagerImpl");
        throw std::runtime_error(
            "ToxAV instance belongs to a different V2TIMManagerImpl");
    }

    TOXAV_ERR_NEW error;
    if (!manager_impl) {
        V2TIMLog::getInstance().Error("[ToxAVManager] V2TIMManagerImpl instance is null (caller must pass valid manager)");
        throw std::runtime_error("V2TIMManagerImpl instance is null");
    }
    V2TIMLog::getInstance().Info("[ToxAVManager] Using V2TIMManagerImpl instance: {}", (void*)manager_impl);
    ToxManager* tox_manager = manager_impl->GetToxManager();
    if (!tox_manager) {
        V2TIMLog::getInstance().Error("[ToxAVManager] ToxManager instance is null");
        throw std::runtime_error("ToxManager instance is null");
    }
    Tox* tox = tox_manager->getTox();
    if (!tox) {
        V2TIMLog::getInstance().Error("[ToxAVManager] Tox instance is null");
        throw std::runtime_error("Tox instance is null");
    }
    this->tox_ = tox;
    toxav_.reset(toxav_new(tox, &error));
    if (!toxav_ || error != TOXAV_ERR_NEW_OK) {
        V2TIMLog::getInstance().Error("[ToxAVManager] ToxAV initialization failed with error: {}", (int)error);
        throw std::runtime_error("ToxAV initialization failed: " + std::to_string(error));
    }
    manager_impl_ = manager_impl;
    V2TIMLog::getInstance().Info("[ToxAVManager] ToxAV initialized successfully");

    // Callbacks. Each one COPIES its slot under the leaf callbacks_mutex_ and
    // invokes the copy with no ToxAVManager lock held: they run on the
    // tox_iterate() thread (call / call_state / bit rates, with toxav's
    // internal mutex held) or inside iterate() (frames, peer timeouts), and the
    // user code they reach may call any ToxAVManager API or setter. Reading
    // the slot unlocked raced with the setters (std::function reassigned while
    // being invoked); taking mutex_ would order it after toxav's own lock,
    // the reverse of every API call.
    toxav_callback_call(toxav_.get(),
        [](ToxAV* av, uint32_t friend_number, bool audio_enabled,
           bool video_enabled, void* user_data) {
            auto self = static_cast<ToxAVManager*>(user_data);
            V2TIMLog::getInstance().Info("[ToxAVManager] on_call callback: friend_number={}, audio={}, video={}", 
                friend_number, audio_enabled, video_enabled);
            CallCallback cb = self ? self->snapshotCallback(self->call_cb_) : CallCallback();
            if (cb) {
                cb(friend_number, audio_enabled, video_enabled);
            } else {
                V2TIMLog::getInstance().Warning("[ToxAVManager] on_call callback not set or self is null");
            }
        }, this);

    toxav_callback_call_state(toxav_.get(),
        [](ToxAV* av, uint32_t friend_number, uint32_t state, void* user_data) {
            auto self = static_cast<ToxAVManager*>(user_data);
            V2TIMLog::getInstance().Info("[ToxAVManager] on_call_state callback: friend_number={}, state={}", 
                friend_number, state);
            CallStateCallback cb = self ? self->snapshotCallback(self->call_state_cb_) : CallStateCallback();
            if (cb) {
                cb(friend_number, state);
            } else {
                V2TIMLog::getInstance().Warning("[ToxAVManager] on_call_state callback not set or self is null");
            }
        }, this);

    toxav_callback_audio_bit_rate(toxav_.get(),
        [](ToxAV* av, uint32_t friend_number, uint32_t audio_bit_rate,
           void* user_data) {
            auto self = static_cast<ToxAVManager*>(user_data);
            AudioBitrateCallback cb = self ? self->snapshotCallback(self->audio_bitrate_cb_) : AudioBitrateCallback();
            if (cb) {
                cb(friend_number, audio_bit_rate);
            }
        }, this);

    toxav_callback_video_bit_rate(toxav_.get(),
        [](ToxAV* av, uint32_t friend_number, uint32_t video_bit_rate,
           void* user_data) {
            auto self = static_cast<ToxAVManager*>(user_data);
            VideoBitrateCallback cb = self ? self->snapshotCallback(self->video_bitrate_cb_) : VideoBitrateCallback();
            if (cb) {
                cb(friend_number, video_bit_rate);
            }
        }, this);

    toxav_callback_audio_receive_frame(toxav_.get(),
        [](ToxAV* av, uint32_t friend_number, const int16_t* pcm,
           size_t sample_count, uint8_t channels, uint32_t sampling_rate,
           void* user_data) {
            auto self = static_cast<ToxAVManager*>(user_data);
            AudioReceiveFrameCallback cb = self ? self->snapshotCallback(self->audio_receive_frame_cb_) : AudioReceiveFrameCallback();
            if (cb) {
                cb(friend_number, pcm, sample_count, channels, sampling_rate);
            }
        }, this);

    toxav_callback_video_receive_frame(toxav_.get(),
        [](ToxAV* av, uint32_t friend_number, uint16_t width, uint16_t height,
           const uint8_t* y, const uint8_t* u, const uint8_t* v,
           int32_t ystride, int32_t ustride, int32_t vstride, void* user_data) {
            auto self = static_cast<ToxAVManager*>(user_data);
            VideoReceiveFrameCallback cb = self ? self->snapshotCallback(self->video_receive_frame_cb_) : VideoReceiveFrameCallback();
            if (cb) {
                cb(friend_number, width, height, y, u, v);
            }
        }, this);
}

// 关闭实现
void ToxAVManager::shutdown() {
    // From inside a ToxAV/tox callback (the user hangs up for good, or logs
    // out, in reaction to a call event): this thread is running toxav_iterate()
    // (holding av_iterate_mutex_) or tox_iterate() (holding ToxManager's
    // iterate lock, with toxav's own mutex held by msi) — both non-recursive
    // for us, and toxav_kill() would free the ToxAV that iterate is walking.
    // Kill it on this thread as soon as that iterate returns.
    if (insideIterateCallback()) {
        std::weak_ptr<int> alive = alive_token_;
        if (IterateReentryScope::Defer([this, alive] {
                if (alive.lock()) shutdown();
            })) {
            V2TIMLog::getInstance().Warning(
                "[ToxAVManager] shutdown() called from inside an iterate callback; deferred until it returns");
        } else {
            V2TIMLog::getInstance().Error(
                "[ToxAVManager] shutdown() called from inside an iterate callback with no iterate scope; ignored");
        }
        return;
    }
    // Lock order (ToxAVManager.h): av_iterate_mutex_ -> ToxManager iterate
    // lock -> mutex_. av_iterate_mutex_ keeps toxav_iterate() out; the iterate
    // lock keeps tox_iterate() out while toxav_kill() unregisters the
    // per-pktid handlers unlocked (see initialize()). The manager is
    // snapshotted outside mutex_, so re-validate under it and retry until the
    // snapshot holds: an initialize() that raced in between would otherwise
    // leave a toxav_ we kill without the iterate lock. No capped fallback —
    // every exit of this loop holds mutex_ AND the matching iterate lock.
    std::unique_lock<std::mutex> av_iterate_lock(av_iterate_mutex_);
    ToxManager* tox_manager = nullptr;
    std::unique_lock<std::mutex> iterate_lock;
    std::unique_lock<std::shared_mutex> lock;
    for (;;) {
        {
            std::shared_lock<std::shared_mutex> snapshot(mutex_);
            tox_manager = manager_impl_ ? manager_impl_->GetToxManager() : nullptr;
        }
        iterate_lock = tox_manager ? tox_manager->lockIterate() : std::unique_lock<std::mutex>();
        lock = std::unique_lock<std::shared_mutex>(mutex_);
        ToxManager* now = manager_impl_ ? manager_impl_->GetToxManager() : nullptr;
        if (now == tox_manager) break;
        lock.unlock();
        iterate_lock = std::unique_lock<std::mutex>();
    }
    V2TIMLog::getInstance().Info("[ToxAVManager] shutdown() called");
    toxav_.reset();
    tox_ = nullptr;
    manager_impl_ = nullptr;
    {
        std::lock_guard<std::mutex> callbacks_lock(callbacks_mutex_);
        conference_audio_callback_ = nullptr;
    }
    V2TIMLog::getInstance().Info("[ToxAVManager] shutdown() completed");
}

bool ToxAVManager::insideIterateCallback() const {
    if (isIterateOwner()) return true;
    V2TIMManagerImpl* impl = nullptr;
    {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        impl = manager_impl_;
    }
    ToxManager* tox_manager = impl ? impl->GetToxManager() : nullptr;
    return tox_manager && tox_manager->isIterateOwner();
}

bool ToxAVManager::setConferenceAudioCallbackContext(
    toxav_audio_data_cb* conference_audio_callback,
    V2TIMManagerImpl* manager_impl) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_ || !conference_audio_callback || !manager_impl ||
        manager_impl != manager_impl_) {
        return false;
    }
    std::lock_guard<std::mutex> callbacks_lock(callbacks_mutex_);
    conference_audio_callback_ = conference_audio_callback;
    return true;
}

// 迭代实现
// toxav_iterate() decodes and delivers audio/video frames (and peer timeouts)
// synchronously through the callbacks above, straight into user code that may
// call back into this manager (answer/end a call, change a bit rate, replace a
// callback). So only av_iterate_mutex_ — which no such call takes — is held
// across it; mutex_ is held just long enough to read toxav_, whose lifetime is
// covered by av_iterate_mutex_ (shutdown() must take it before toxav_kill()).
// ToxAV is internally locked, so API calls running concurrently are safe.
void ToxAVManager::iterate() {
    if (isIterateOwner()) return;  // re-entered from one of our own callbacks
    // FIRST local: work deferred by callbacks (shutdown, UnInitSDK) runs when
    // this scope ends, after the lock and owner mark below are released.
    IterateReentryScope reentry_scope;
    std::unique_lock<std::mutex> av_iterate_lock(av_iterate_mutex_);
    av_iterate_owner_.store(std::this_thread::get_id(), std::memory_order_release);
    struct OwnerReset {
        std::atomic<std::thread::id>& owner;
        ~OwnerReset() { owner.store(std::thread::id(), std::memory_order_release); }
    } owner_reset{av_iterate_owner_};
    ToxAV* av = nullptr;
    {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        av = toxav_.get();
    }
    if (av) {
        toxav_iterate(av);
    }
}

// 音频/视频控制实现
bool ToxAVManager::startCall(uint32_t friend_number, uint32_t audio_bit_rate,
                           uint32_t video_bit_rate) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    V2TIMLog::getInstance().Info("[ToxAVManager] startCall() called: friend_number={}, audio_bit_rate={}, video_bit_rate={}", 
        friend_number, audio_bit_rate, video_bit_rate);
    if (!toxav_) {
        V2TIMLog::getInstance().Error("[ToxAVManager] startCall() failed: ToxAV not initialized");
        return false;
    }
    TOXAV_ERR_CALL error;
    bool result = toxav_call(toxav_.get(), friend_number, audio_bit_rate,
                     video_bit_rate, &error);
    if (result && error == TOXAV_ERR_CALL_OK) {
        V2TIMLog::getInstance().Info("[ToxAVManager] startCall() succeeded: friend_number={}", friend_number);
    } else {
        const char* errorStr = "UNKNOWN";
        switch (error) {
            case TOXAV_ERR_CALL_OK: errorStr = "OK"; break;
            case TOXAV_ERR_CALL_MALLOC: errorStr = "MALLOC"; break;
            case TOXAV_ERR_CALL_SYNC: errorStr = "SYNC"; break;
            case TOXAV_ERR_CALL_FRIEND_NOT_FOUND: errorStr = "FRIEND_NOT_FOUND"; break;
            case TOXAV_ERR_CALL_FRIEND_NOT_CONNECTED: errorStr = "FRIEND_NOT_CONNECTED"; break;
            case TOXAV_ERR_CALL_FRIEND_ALREADY_IN_CALL: errorStr = "FRIEND_ALREADY_IN_CALL"; break;
            case TOXAV_ERR_CALL_INVALID_BIT_RATE: errorStr = "INVALID_BIT_RATE"; break;
            default: errorStr = "UNKNOWN"; break;
        }
        V2TIMLog::getInstance().Error("[ToxAVManager] startCall() failed: friend_number={}, error={} ({})", 
            friend_number, (int)error, errorStr);
    }
    return result && error == TOXAV_ERR_CALL_OK;
}

bool ToxAVManager::endCall(uint32_t friend_number) {
    // CANCEL frees the ToxAVCall (decoders, call mutex) and msi's MSICall.
    // From inside a callback those are still in use once it returns — by
    // toxav_iterate's decode loop for frame callbacks, by msi's packet handler
    // for call / call-state callbacks — so hang up right after that iterate.
    if (insideIterateCallback()) {
        std::weak_ptr<int> alive = alive_token_;
        if (IterateReentryScope::Defer([this, alive, friend_number] {
                if (alive.lock()) endCall(friend_number);
            })) {
            V2TIMLog::getInstance().Info(
                "[ToxAVManager] endCall() from inside a callback: friend_number={} scheduled after the iterate",
                friend_number);
            return true;
        }
    }
    std::shared_lock<std::shared_mutex> lock(mutex_);
    V2TIMLog::getInstance().Info("[ToxAVManager] endCall() called: friend_number={}", friend_number);
    if (!toxav_) {
        V2TIMLog::getInstance().Error("[ToxAVManager] endCall() failed: ToxAV not initialized");
        return false;
    }
    TOXAV_ERR_CALL_CONTROL error;
    bool result = toxav_call_control(toxav_.get(), friend_number,
                            TOXAV_CALL_CONTROL_CANCEL, &error);
    if (result && error == TOXAV_ERR_CALL_CONTROL_OK) {
        V2TIMLog::getInstance().Info("[ToxAVManager] endCall() succeeded: friend_number={}", friend_number);
    } else {
        V2TIMLog::getInstance().Error("[ToxAVManager] endCall() failed: friend_number={}, error={}", 
            friend_number, (int)error);
    }
    return result && error == TOXAV_ERR_CALL_CONTROL_OK;
}

bool ToxAVManager::answerCall(uint32_t friend_number, uint32_t audio_bit_rate, uint32_t video_bit_rate) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    V2TIMLog::getInstance().Info("[ToxAVManager] answerCall() called: friend_number={}, audio_bit_rate={}, video_bit_rate={}", 
        friend_number, audio_bit_rate, video_bit_rate);
    if (!toxav_) {
        V2TIMLog::getInstance().Error("[ToxAVManager] answerCall() failed: ToxAV not initialized");
        return false;
    }
    TOXAV_ERR_ANSWER error;
    bool result = toxav_answer(toxav_.get(), friend_number, audio_bit_rate, video_bit_rate, &error);
    if (result && error == TOXAV_ERR_ANSWER_OK) {
        V2TIMLog::getInstance().Info("[ToxAVManager] answerCall() succeeded: friend_number={}", friend_number);
    } else {
        V2TIMLog::getInstance().Error("[ToxAVManager] answerCall() failed: friend_number={}, error={}", 
            friend_number, (int)error);
    }
    return result && error == TOXAV_ERR_ANSWER_OK;
}

bool ToxAVManager::muteAudio(uint32_t friend_number, bool mute) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_) return false;
    TOXAV_ERR_CALL_CONTROL error;
    return toxav_call_control(toxav_.get(), friend_number,
                            mute ? TOXAV_CALL_CONTROL_MUTE_AUDIO
                                : TOXAV_CALL_CONTROL_UNMUTE_AUDIO,
                            &error) && error == TOXAV_ERR_CALL_CONTROL_OK;
}

bool ToxAVManager::muteVideo(uint32_t friend_number, bool mute) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_) return false;
    TOXAV_ERR_CALL_CONTROL error;
    return toxav_call_control(toxav_.get(), friend_number,
                            mute ? TOXAV_CALL_CONTROL_HIDE_VIDEO
                                : TOXAV_CALL_CONTROL_SHOW_VIDEO,
                            &error) && error == TOXAV_ERR_CALL_CONTROL_OK;
}

bool ToxAVManager::sendAudioFrame(uint32_t friend_number, const int16_t* pcm,
                                size_t sample_count, uint8_t channels,
                                uint32_t sampling_rate) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_) return false;
    TOXAV_ERR_SEND_FRAME error;
    return toxav_audio_send_frame(toxav_.get(), friend_number, pcm,
                                sample_count, channels, sampling_rate,
                                &error) && error == TOXAV_ERR_SEND_FRAME_OK;
}

// Legacy group AV (toxav_old.c / groupav.c) predates toxcore's per-instance
// lock: toxav_groupchat_enable_av / _disable_av / toxav_group_send_audio reach
// straight into the conferences object without tox_lock(). They are called
// from the FFI (Dart) thread while event_thread_ is inside tox_iterate()
// decoding group audio — and disable_av FREES the peer_av decoders and the
// group_av that handle_group_audio_packet is using. Serialize them with the
// iterate the same way initialize()/shutdown() do: iterate lock first, then
// mutex_. lockIterate() is a no-op on the iterate thread itself.
std::unique_lock<std::mutex> ToxAVManager::lockToxIterate() const {
    V2TIMManagerImpl* impl = nullptr;
    {
        std::shared_lock<std::shared_mutex> lock(mutex_);
        impl = manager_impl_;
    }
    if (impl && impl->GetToxManager()) {
        return impl->GetToxManager()->lockIterate();
    }
    return std::unique_lock<std::mutex>();
}

bool ToxAVManager::sendConferenceAudioFrame(
    uint32_t conference_number, const int16_t* pcm, size_t sample_count,
    uint8_t channels, uint32_t sampling_rate) {
    auto iterate_lock = lockToxIterate();
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_ || !pcm || sample_count == 0 || sample_count > UINT32_MAX) {
        return false;
    }
    return toxav_group_send_audio(tox_, ConferenceNumberFromKey(conference_number), pcm,
                                  static_cast<uint32_t>(sample_count), channels,
                                  sampling_rate) == 0;
}

bool ToxAVManager::enableConferenceAudio(uint32_t conference_number) {
    auto iterate_lock = lockToxIterate();
    std::shared_lock<std::shared_mutex> lock(mutex_);
    toxav_audio_data_cb* audio_callback = nullptr;
    {
        std::lock_guard<std::mutex> callbacks_lock(callbacks_mutex_);
        audio_callback = conference_audio_callback_;
    }
    if (!toxav_ || !manager_impl_ || !audio_callback) return false;
    return toxav_groupchat_enable_av(tox_, ConferenceNumberFromKey(conference_number),
                                     audio_callback, manager_impl_) == 0;
}

bool ToxAVManager::disableConferenceAudio(uint32_t conference_number) {
    auto iterate_lock = lockToxIterate();
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_) return false;
    return toxav_groupchat_disable_av(tox_, ConferenceNumberFromKey(conference_number)) == 0;
}

bool ToxAVManager::isConferenceAudioEnabled(uint32_t conference_number) const {
    auto iterate_lock = lockToxIterate();
    std::shared_lock<std::shared_mutex> lock(mutex_);
    return tox_ && toxav_groupchat_av_enabled(tox_, ConferenceNumberFromKey(conference_number));
}

bool ToxAVManager::sendVideoFrame(uint32_t friend_number, uint16_t width,
                                uint16_t height, const uint8_t* y,
                                const uint8_t* u, const uint8_t* v) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_) return false;
    TOXAV_ERR_SEND_FRAME error;
    return toxav_video_send_frame(toxav_.get(), friend_number, width, height,
                                y, u, v, &error) && error == TOXAV_ERR_SEND_FRAME_OK;
}

bool ToxAVManager::setAudioBitRate(uint32_t friend_number, uint32_t audio_bit_rate) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_) return false;
    TOXAV_ERR_BIT_RATE_SET error;
    return toxav_audio_set_bit_rate(toxav_.get(), friend_number, audio_bit_rate, &error) &&
           error == TOXAV_ERR_BIT_RATE_SET_OK;
}

bool ToxAVManager::setVideoBitRate(uint32_t friend_number, uint32_t video_bit_rate) {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    if (!toxav_) return false;
    TOXAV_ERR_BIT_RATE_SET error;
    return toxav_video_set_bit_rate(toxav_.get(), friend_number, video_bit_rate, &error) &&
           error == TOXAV_ERR_BIT_RATE_SET_OK;
}

// 回调设置实现
// Only the leaf callbacks_mutex_: a setter may be called from inside a
// callback. The previous callback is swapped out and destroyed after the lock
// is released (its captures' destructors must not run under the lock).
void ToxAVManager::setCallCallback(CallCallback cb) {
    std::lock_guard<std::mutex> lock(callbacks_mutex_);
    call_cb_.swap(cb);
}

void ToxAVManager::setCallStateCallback(CallStateCallback cb) {
    std::lock_guard<std::mutex> lock(callbacks_mutex_);
    call_state_cb_.swap(cb);
}

void ToxAVManager::setAudioBitrateCallback(AudioBitrateCallback cb) {
    std::lock_guard<std::mutex> lock(callbacks_mutex_);
    audio_bitrate_cb_.swap(cb);
}

void ToxAVManager::setVideoBitrateCallback(VideoBitrateCallback cb) {
    std::lock_guard<std::mutex> lock(callbacks_mutex_);
    video_bitrate_cb_.swap(cb);
}

void ToxAVManager::setAudioReceiveFrameCallback(AudioReceiveFrameCallback cb) {
    std::lock_guard<std::mutex> lock(callbacks_mutex_);
    audio_receive_frame_cb_.swap(cb);
}

void ToxAVManager::setVideoReceiveFrameCallback(VideoReceiveFrameCallback cb) {
    std::lock_guard<std::mutex> lock(callbacks_mutex_);
    video_receive_frame_cb_.swap(cb);
}

ToxAV* ToxAVManager::getToxAV() const {
    std::shared_lock<std::shared_mutex> lock(mutex_);
    return toxav_.get();
}
