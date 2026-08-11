#ifndef WHISPER_TRANSCRIBER_BRIDGE_H
#define WHISPER_TRANSCRIBER_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wt_run wt_run;

typedef struct {
    int64_t start_milliseconds;
    int64_t end_milliseconds;
    const char * text;
} wt_segment;

// Creates an opaque run handle. The handle owns no model or audio data until execute.
wt_run * wt_run_create(const char * model_path, const char * pcm_path, const char * language);

// Runs inference synchronously on the caller's worker queue. Returns 0 on success.
int wt_run_execute(wt_run * run);

// Requests cooperative cancellation. It is safe to call from another thread.
void wt_run_cancel(wt_run * run);

// Returns the latest Whisper progress value in the range 0...100.
int wt_run_progress(const wt_run * run);

// Returns a stable error message owned by the run handle.
const char * wt_run_error(const wt_run * run);

int wt_run_segment_count(const wt_run * run);
wt_segment wt_run_segment_at(const wt_run * run, int index);

void wt_run_destroy(wt_run * run);

#ifdef __cplusplus
}
#endif

#endif
