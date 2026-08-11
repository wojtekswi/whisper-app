#include "WhisperBridge.h"

#include "whisper.h"

#include <algorithm>
#include <atomic>
#include <climits>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct wt_owned_segment {
    int64_t start_milliseconds;
    int64_t end_milliseconds;
    std::string text;
};

struct wt_run {
    std::string model_path;
    std::string pcm_path;
    std::string language;
    std::string error;
    std::atomic_bool cancelled { false };
    std::atomic_int progress { 0 };
    std::vector<wt_owned_segment> segments;
};

static void wt_progress_callback(
        struct whisper_context *,
        struct whisper_state *,
        int progress,
        void * user_data) {
    static_cast<wt_run *>(user_data)->progress.store(std::max(0, std::min(progress, 100)));
}

static bool wt_abort_callback(void * user_data) {
    return static_cast<wt_run *>(user_data)->cancelled.load();
}

static int wt_thread_count() {
    const long cores = sysconf(_SC_NPROCESSORS_ONLN);
    return static_cast<int>(std::max(1L, std::min(8L, cores - 2)));
}

wt_run * wt_run_create(const char * model_path, const char * pcm_path, const char * language) {
    if (model_path == nullptr || pcm_path == nullptr) {
        return nullptr;
    }

    auto * run = new wt_run;
    run->model_path = model_path;
    run->pcm_path = pcm_path;
    run->language = language == nullptr ? "auto" : language;
    return run;
}

int wt_run_execute(wt_run * run) {
    if (run == nullptr) {
        return -1;
    }

    int file_descriptor = -1;
    void * mapping = MAP_FAILED;
    size_t byte_count = 0;
    struct whisper_context * context = nullptr;

    try {
        struct stat file_status {};
        if (stat(run->pcm_path.c_str(), &file_status) != 0 || file_status.st_size <= 0) {
            run->error = "Prepared audio is empty or unavailable.";
            return -1;
        }

        if (file_status.st_size % static_cast<off_t>(sizeof(float)) != 0) {
            run->error = "Prepared audio is not aligned to Float32 samples.";
            return -1;
        }

        const uint64_t sample_count = static_cast<uint64_t>(file_status.st_size / sizeof(float));
        if (sample_count > static_cast<uint64_t>(INT_MAX)) {
            run->error = "Prepared audio exceeds Whisper's sample limit.";
            return -1;
        }

        file_descriptor = open(run->pcm_path.c_str(), O_RDONLY);
        if (file_descriptor < 0) {
            run->error = "Prepared audio could not be opened.";
            return -1;
        }

        byte_count = static_cast<size_t>(file_status.st_size);
        mapping = mmap(nullptr, byte_count, PROT_READ, MAP_PRIVATE, file_descriptor, 0);
        if (mapping == MAP_FAILED) {
            run->error = "Prepared audio could not be memory-mapped.";
            close(file_descriptor);
            return -1;
        }

        auto context_params = whisper_context_default_params();
        context_params.use_gpu = true;
        context_params.flash_attn = true;
        context = whisper_init_from_file_with_params(run->model_path.c_str(), context_params);
        if (context == nullptr) {
            run->error = "Whisper could not load the selected model.";
            munmap(mapping, byte_count);
            close(file_descriptor);
            return -1;
        }

        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.print_realtime = false;
        params.print_progress = false;
        params.print_timestamps = false;
        params.print_special = false;
        params.translate = false;
        params.no_context = true;
        params.n_threads = wt_thread_count();
        params.language = run->language.empty() || run->language == "auto" ? "auto" : run->language.c_str();
        params.progress_callback = wt_progress_callback;
        params.progress_callback_user_data = run;
        params.abort_callback = wt_abort_callback;
        params.abort_callback_user_data = run;

        const int result = whisper_full(
                context,
                params,
                static_cast<const float *>(mapping),
                static_cast<int>(sample_count));
        if (result != 0) {
            run->error = run->cancelled.load() ? "Transcription cancelled." : "Whisper could not transcribe this file.";
            whisper_free(context);
            munmap(mapping, byte_count);
            close(file_descriptor);
            return -1;
        }

        const int segment_count = whisper_full_n_segments(context);
        run->segments.clear();
        run->segments.reserve(std::max(0, segment_count));
        for (int index = 0; index < segment_count; ++index) {
            const char * text = whisper_full_get_segment_text(context, index);
            run->segments.push_back({
                whisper_full_get_segment_t0(context, index) * 10,
                whisper_full_get_segment_t1(context, index) * 10,
                text == nullptr ? "" : text
            });
        }

        run->progress.store(100);
        whisper_free(context);
        munmap(mapping, byte_count);
        close(file_descriptor);
        return 0;
    } catch (const std::exception & exception) {
        run->error = exception.what();
    } catch (...) {
        run->error = "The native transcription engine failed unexpectedly.";
    }

    if (context != nullptr) {
        whisper_free(context);
    }
    if (mapping != MAP_FAILED) {
        munmap(mapping, byte_count);
    }
    if (file_descriptor >= 0) {
        close(file_descriptor);
    }
    return -1;
}

void wt_run_cancel(wt_run * run) {
    if (run != nullptr) {
        run->cancelled.store(true);
    }
}

int wt_run_progress(const wt_run * run) {
    return run == nullptr ? 0 : run->progress.load();
}

const char * wt_run_error(const wt_run * run) {
    return run == nullptr ? "The native transcription run is unavailable." : run->error.c_str();
}

int wt_run_segment_count(const wt_run * run) {
    return run == nullptr ? 0 : static_cast<int>(run->segments.size());
}

wt_segment wt_run_segment_at(const wt_run * run, int index) {
    if (run == nullptr || index < 0 || index >= static_cast<int>(run->segments.size())) {
        return { 0, 0, "" };
    }

    const auto & segment = run->segments[static_cast<size_t>(index)];
    return { segment.start_milliseconds, segment.end_milliseconds, segment.text.c_str() };
}

void wt_run_destroy(wt_run * run) {
    delete run;
}
