/*
 * SysMixer DSP regression test: pan laws, auto-mono latch/unlatch,
 * mute ramp, fader-off, summing, meters. Run via `make test`.
 */

#include "src/DistrhoPluginInternal.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>

USE_NAMESPACE_DISTRHO

static bool requestStub(void*, uint32_t, float) { return true; }

static int gFailures = 0;

static void expectNear(const char* what, float actual, float expected, float tol)
{
    if (std::fabs(actual - expected) > tol)
    {
        std::printf("FAIL: %s — expected %.6f, got %.6f\n", what, expected, actual);
        ++gFailures;
    }
}

static constexpr uint32_t kBlock = 128;          // 2x the internal chunk + odd tail below
static constexpr float    kFs    = 48000.0f;
static constexpr int kChannels = 16, kIns = 2 * kChannels;
static float in[kIns][kBlock], outL[kBlock], outR[kBlock];

// Plugin-side indices (see ParamIndex).
static uint32_t gain(uint32_t ch) { return ch * 3; }
static uint32_t pan(uint32_t ch)  { return ch * 3 + 1; }
static uint32_t mute(uint32_t ch) { return ch * 3 + 2; }
static constexpr uint32_t kMaster = kChannels * 3, kLevel1 = kMaster + 1,
                          kStereo1 = kLevel1 + kChannels, kLevelL = kStereo1 + kChannels;

static void clearInputs() { std::memset(in, 0, sizeof(in)); }

static void run(PluginExporter& p, uint32_t frames = kBlock)
{
    const float* ins[kIns];
    for (int i = 0; i < kIns; ++i) ins[i] = in[i];
    float* outs[2] = { outL, outR };
    p.run(ins, outs, frames);
}

int main()
{
    d_nextBufferSize = kBlock;
    d_nextSampleRate = kFs;
    d_nextCanRequestParameterValueChanges = true;

    PluginExporter p(nullptr, nullptr, requestStub, nullptr);
    p.activate();

    const float h = std::sqrt(0.5f);

    // 1. Mono (R unconnected = zeros): L feeds both sides at -3 dB.
    clearInputs();
    for (uint32_t i = 0; i < kBlock; ++i) in[0][i] = 0.5f;
    run(p);
    expectNear("mono centre L", outL[64], 0.5f * h, 1e-5f);
    expectNear("mono centre R", outR[64], 0.5f * h, 1e-5f);
    expectNear("mono flag", p.getParameterValue(kStereo1), 0.0f, 0.0f);
    expectNear("meter -6 dB", p.getParameterValue(kLevel1), -6.0206f, 0.01f);

    // 2. Mono hard-left pan: all to L (after ramp block).
    p.setParameterValue(pan(0), -1.0f);
    run(p); run(p);
    expectNear("mono hard-left L", outL[10], 0.5f, 1e-5f);
    expectNear("mono hard-left R", outR[10], 0.0f, 1e-6f);
    p.setParameterValue(pan(0), 0.0f);
    run(p);

    // 3. R gets signal -> latches stereo, centre balance is unity.
    for (uint32_t i = 0; i < kBlock; ++i) in[1][i] = -0.25f;
    run(p); run(p);
    expectNear("stereo flag", p.getParameterValue(kStereo1), 1.0f, 0.0f);
    expectNear("stereo L", outL[10], 0.5f, 1e-5f);
    expectNear("stereo R", outR[10], -0.25f, 1e-5f);

    // 4. Once stereo, a silent R stays silent: no drift back to mono, however
    //    long (hard-panned source; mod-ui never pulls an R cable mid-set).
    for (uint32_t i = 0; i < kBlock; ++i) in[1][i] = 0.0f;
    const uint32_t blocksPerSec = static_cast<uint32_t>(kFs) / kBlock;
    for (uint32_t b = 0; b < 3 * blocksPerSec; ++b) run(p);
    expectNear("stays stereo with silent R", p.getParameterValue(kStereo1), 1.0f, 0.0f);
    expectNear("hard-panned stereo stays on L only", outR[10], 0.0f, 1e-6f);

    // 5. Reactivation (pedalboard reload) starts mono again.
    p.deactivate();
    p.activate();
    run(p); run(p);
    expectNear("mono after reactivate", p.getParameterValue(kStereo1), 0.0f, 0.0f);
    expectNear("mono after reactivate R", outR[10], 0.5f * h, 1e-5f);

    // 6. Summing two channels + master gain, odd block size (chunk tail).
    clearInputs();
    for (uint32_t i = 0; i < kBlock; ++i) { in[2][i] = 0.1f; in[3][i] = 0.1f; in[4][i] = 0.2f; in[5][i] = 0.2f; }
    p.setParameterValue(kMaster, -6.0206f);
    run(p, 100); run(p, 100);
    expectNear("sum of two stereo channels at -6 dB master", outL[99], 0.15f, 1e-4f);
    // Meter is peak-with-release: it may sit above the current level, never below.
    if (p.getParameterValue(kLevelL) < 20.0f * std::log10(0.15f) - 0.05f)
    { std::printf("FAIL: master meter below signal\n"); ++gFailures; }

    // 7. Mute ramps to zero within one block, fader floor is off.
    p.setParameterValue(kMaster, 0.0f);
    p.setParameterValue(mute(1), 1.0f);
    p.setParameterValue(gain(2), -60.0f);
    run(p);
    expectNear("mute ramp starts near old value", outL[0], 0.15f, 0.01f);  // master was -6 dB
    run(p);
    expectNear("muted + fader off -> silence", outL[64], 0.0f, 1e-7f);
    expectNear("meter still shows muted input", p.getParameterValue(kLevel1 + 1), 20.0f * std::log10(0.1f), 0.05f);

    // 8. In-place: output buffer aliasing an input buffer.
    clearInputs();
    p.setParameterValue(mute(1), 0.0f);
    p.setParameterValue(gain(2), 0.0f);
    for (uint32_t i = 0; i < kBlock; ++i) { in[2][i] = 0.1f; in[3][i] = 0.1f; in[4][i] = 0.1f; in[5][i] = 0.1f; }
    run(p);
    {
        const float* ins[kIns];
        for (int i = 0; i < kIns; ++i) ins[i] = in[i];
        float* outs[2] = { in[2], in[3] };   // aliased onto channel 2's inputs
        p.run(ins, outs, kBlock);
        expectNear("aliased output", in[2][kBlock - 1], 0.2f, 1e-5f);
    }

    // 9. Last channel is wired (mono, centre).
    clearInputs();
    p.setParameterValue(gain(2), -60.0f);   // drop ch3 left over from 8.
    for (uint32_t i = 0; i < kBlock; ++i) in[kIns - 2][i] = 0.5f;
    run(p); run(p);
    expectNear("channel 16 mono centre", outR[64], 0.5f * h, 1e-5f);

    if (gFailures != 0)
    {
        std::printf("%d failure(s)\n", gFailures);
        return 1;
    }
    std::printf("ok: pan laws, auto-mono, mute ramp, summing, meters, aliasing\n");
    return 0;
}
