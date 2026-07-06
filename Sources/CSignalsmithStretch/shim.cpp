// The only C++ translation unit in the package: wraps the vendored
// signalsmith-stretch template behind the flat-C API in
// include/csignalsmith_stretch.h so Swift never imports C++ templates.
// Compiled with SIGNALSMITH_USE_ACCELERATE (Package.swift) so the FFT and
// vector ops go through vDSP.

#include "include/csignalsmith_stretch.h"

#include "signalsmith-stretch/signalsmith-stretch.h"

#include <new>

using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

struct css_stretch {
    Stretch stretch;
    float sampleRate;

    css_stretch(long long seed, float rate)
        : stretch(static_cast<long>(seed)), sampleRate(rate) {}
};

extern "C" {

css_stretch *css_create(int channels, float sampleRate, long long seed) {
    auto *s = new (std::nothrow) css_stretch(seed, sampleRate);
    if (s == nullptr) return nullptr;
    s->stretch.presetDefault(channels, sampleRate);
    return s;
}

void css_destroy(css_stretch *s) {
    delete s;
}

void css_reset(css_stretch *s) {
    s->stretch.reset();
}

void css_set_transpose_semitones(css_stretch *s, float semitones,
                                 float tonalityLimitHz) {
    // signalsmith expresses the tonality limit as a fraction of sample rate.
    float limit = (tonalityLimitHz > 0) ? tonalityLimitHz / s->sampleRate : 0;
    s->stretch.setTransposeSemitones(semitones, limit);
}

void css_set_formant_preserve(css_stretch *s, bool preserve) {
    // Formant factor 1 (no formant shift of its own); compensatePitch=true
    // holds the formant envelope at the source position while pitch moves.
    s->stretch.setFormantFactor(1, preserve);
    s->stretch.setFormantBase(0); // auto-detect fundamental
}

int css_input_latency(const css_stretch *s) {
    return s->stretch.inputLatency();
}

int css_output_latency(const css_stretch *s) {
    return s->stretch.outputLatency();
}

void css_output_seek(css_stretch *s, const float *const *inputs,
                     int inputFrames) {
    s->stretch.outputSeek(inputs, inputFrames);
}

void css_process(css_stretch *s, const float *const *inputs, int inputFrames,
                 float *const *outputs, int outputFrames) {
    s->stretch.process(inputs, inputFrames, outputs, outputFrames);
}

void css_flush(css_stretch *s, float *const *outputs, int outputFrames,
               double playbackRate) {
    s->stretch.flush(outputs, outputFrames, static_cast<float>(playbackRate));
}

} // extern "C"
