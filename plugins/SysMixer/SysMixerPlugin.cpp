/*
 * SysMixer — the pedalboard-wide mixer: 16 stereo channels into one
 * stereo bus, built to be light. mod-ui (stefdoerr fork) hides it and
 * drives it through "Send to mixer"; anywhere else it is a normal plugin.
 *
 * Per channel: gain (dB), pan, mute, plus a pre-fader peak meter and a
 * stereo/mono indicator. Master: gain + L/R peak meters.
 *
 * Auto-mono: an LV2 plugin can't see whether a port is connected; an
 * unconnected input just reads exact zeros. A channel therefore plays as
 * mono (L sent to both sides, constant-power pan) until its R input
 * carries any non-zero sample, then it latches stereo (pan = balance) until
 * the plugin is reactivated. No way back to mono while running: mod-ui does
 * all the wiring here, so an R cable is never pulled mid-set, and a silent R
 * on a stereo source (hard-panned, a pause in a ping-pong) must stay silent.
 *
 * Cost: per channel per sample ~2 multiply-adds plus a peak scan. A
 * channel whose fader is at -60 dB or muted skips the mix loop entirely.
 * Everything transcendental (pow, cos, sin, exp) runs only when a
 * parameter or the block size changes, never per sample.
 */

#include "DistrhoPlugin.hpp"

#include <cmath>
#include <cstring>

START_NAMESPACE_DISTRHO

static constexpr uint32_t kChannels  = 16;
static constexpr uint32_t kChunk     = 64;     // stack accumulator size
static constexpr float    kMinDb     = -60.0f; // fader floor = off, meter floor
static constexpr float    kMaxDb     = 12.0f;
static constexpr float    kHalfPi    = 1.5707963267948966f;
static constexpr float    kMeterFall = 0.3f;   // meter release time constant, s

class SysMixerPlugin : public Plugin
{
public:
    // Inputs: per channel {gain, pan, mute}, then master. Outputs after.
    // Never reorder — saved pedalboards reference these by symbol/index.
    enum ParamIndex {
        kParamChannelBase = 0,                          // ch*3 + {0,1,2}
        kParamMaster      = kChannels * 3,              // 48
        kParamLevelBase,                                // 49..64 channel meters
        kParamStereoBase  = kParamLevelBase + kChannels, // 65..80 stereo flags
        kParamLevelL      = kParamStereoBase + kChannels, // 81
        kParamLevelR,                                   // 82
        kNumParams
    };
    enum { kGain = 0, kPan, kMute };

    enum GroupId { kGroupMaster = kChannels };          // channels use 0..15

    SysMixerPlugin()
        : Plugin(kNumParams, 0, 0)
    {
        for (uint32_t c = 0; c < kChannels; ++c)
        {
            fGainDb[c] = 0.0f;
            fPan[c]    = 0.0f;
            fMute[c]   = false;
            fStereo[c] = false;
            fMeter[c]  = 0.0f;
            fMeterDb[c] = kMinDb;
        }
        updateTargets();
        resetRamps();
    }

protected:
    // ---------------- Information ----------------

    const char* getLabel()       const override { return "sysmixer"; }
    const char* getMaker()       const override { return DISTRHO_PLUGIN_BRAND; }
    const char* getHomePage()    const override { return PLUGIN_HOMEPAGE; }
    const char* getLicense()     const override { return "ISC"; }
    uint32_t    getVersion()     const override
    {
#ifdef PLUGIN_VERSION_MAJOR
        return d_version(PLUGIN_VERSION_MAJOR, PLUGIN_VERSION_MINOR, PLUGIN_VERSION_MICRO);
#else
        return d_version(0, 0, 0);
#endif
    }
    const char* getDescription() const override
    {
        return "The pedalboard-wide mixer: 16 stereo channels into one output, with level meters. "
               "Right-click a plugin (or use +) and choose Send to mixer; the pedal grows a row per channel.";
    }

    int64_t getUniqueId() const override
    {
#ifdef SYSMIXER_BETA
        return d_cconst('s', 'S', 'M', 'B');
#else
        return d_cconst('s', 'S', 'M', 'x');
#endif
    }

    // ---------------- Init ----------------

    void initAudioPort(bool input, uint32_t index, AudioPort& port) override
    {
        if (input)
        {
            const uint32_t ch = index / 2 + 1;
            const bool right = index & 1;
            port.name   = String("In ") + String(ch) + (right ? " R" : " L");
            port.symbol = String("in") + String(ch) + (right ? "_r" : "_l");
        }
        else
        {
            port.name   = index == 0 ? "Out L" : "Out R";
            port.symbol = index == 0 ? "out_l" : "out_r";
            port.groupId = kPortGroupStereo;
        }
    }

    void initPortGroup(uint32_t groupId, PortGroup& portGroup) override
    {
        // Zero-padded, both of them: depending on the MOD-UI, bands are ordered
        // by group symbol or (starless) by group name, as plain strings either
        // way, so "Channel 10" would land before "Channel 2".
        if (groupId < kChannels)
        {
            portGroup.name   = String(groupId < 9 ? "Channel 0" : "Channel ") + String(groupId + 1);
            portGroup.symbol = String(groupId < 9 ? "g0" : "g") + String(groupId + 1) + "_ch" + String(groupId + 1);
        }
        else if (groupId == kGroupMaster)
        {
            portGroup.name   = "Master";
            portGroup.symbol = "g17_master";
        }
        else
        {
            Plugin::initPortGroup(groupId, portGroup);
        }
    }

    void initParameter(uint32_t index, Parameter& parameter) override
    {
        if (index < kParamMaster)
        {
            const uint32_t c = index / 3;
            const String n(c + 1);
            parameter.groupId = c;
            switch (index % 3)
            {
            case kGain:
                parameter.hints      = kParameterIsAutomatable;
                parameter.name       = String("Gain ") + n;
                parameter.symbol     = String("gain") + n;
                parameter.unit       = "dB";
                parameter.ranges.min = kMinDb;
                parameter.ranges.max = kMaxDb;
                parameter.ranges.def = 0.0f;
                break;
            case kPan:
                parameter.hints      = kParameterIsAutomatable;
                parameter.name       = String("Pan ") + n;
                parameter.symbol     = String("pan") + n;
                parameter.ranges.min = -1.0f;
                parameter.ranges.max =  1.0f;
                parameter.ranges.def =  0.0f;
                break;
            case kMute:
                parameter.hints      = kParameterIsAutomatable | kParameterIsBoolean | kParameterIsInteger;
                parameter.name       = String("Mute ") + n;
                parameter.symbol     = String("mute") + n;
                parameter.ranges.min = 0.0f;
                parameter.ranges.max = 1.0f;
                parameter.ranges.def = 0.0f;
                break;
            }
            return;
        }

        if (index == kParamMaster)
        {
            parameter.hints      = kParameterIsAutomatable;
            parameter.name       = "Master";
            parameter.symbol     = "master";
            parameter.unit       = "dB";
            parameter.ranges.min = kMinDb;
            parameter.ranges.max = kMaxDb;
            parameter.ranges.def = 0.0f;
            parameter.groupId    = kGroupMaster;
            return;
        }

        if (index < kParamStereoBase)
        {
            const uint32_t c = index - kParamLevelBase;
            const String n(c + 1);
            parameter.hints      = kParameterIsOutput;
            parameter.name       = String("Level ") + n;
            parameter.symbol     = String("level") + n;
            parameter.unit       = "dB";
            parameter.ranges.min = kMinDb;
            parameter.ranges.max = kMaxDb;
            parameter.ranges.def = kMinDb;
            parameter.groupId    = c;
            return;
        }

        if (index < kParamLevelL)
        {
            const uint32_t c = index - kParamStereoBase;
            const String n(c + 1);
            parameter.hints      = kParameterIsOutput | kParameterIsBoolean | kParameterIsInteger;
            parameter.name       = String("Stereo ") + n;
            parameter.symbol     = String("stereo") + n;
            parameter.ranges.min = 0.0f;
            parameter.ranges.max = 1.0f;
            parameter.ranges.def = 0.0f;
            parameter.groupId    = c;
            return;
        }

        const bool right = index == kParamLevelR;
        parameter.hints      = kParameterIsOutput;
        parameter.name       = right ? "Level R" : "Level L";
        parameter.symbol     = right ? "level_r" : "level_l";
        parameter.unit       = "dB";
        parameter.ranges.min = kMinDb;
        parameter.ranges.max = kMaxDb;
        parameter.ranges.def = kMinDb;
        parameter.groupId    = kGroupMaster;
    }

    // ---------------- State access ----------------

    float getParameterValue(uint32_t index) const override
    {
        if (index < kParamMaster)
        {
            const uint32_t c = index / 3;
            switch (index % 3)
            {
            case kGain: return fGainDb[c];
            case kPan:  return fPan[c];
            case kMute: return fMute[c] ? 1.0f : 0.0f;
            }
        }
        if (index == kParamMaster)  return fMasterDb;
        if (index < kParamStereoBase) return fMeterDb[index - kParamLevelBase];
        if (index < kParamLevelL)   return fStereo[index - kParamStereoBase] ? 1.0f : 0.0f;
        if (index == kParamLevelL)  return fMeterDbL;
        if (index == kParamLevelR)  return fMeterDbR;
        return 0.0f;
    }

    void setParameterValue(uint32_t index, float value) override
    {
        if (index < kParamMaster)
        {
            const uint32_t c = index / 3;
            switch (index % 3)
            {
            case kGain: fGainDb[c] = clamp(value, kMinDb, kMaxDb); break;
            case kPan:  fPan[c]    = clamp(value, -1.0f, 1.0f);    break;
            case kMute: fMute[c]   = value > 0.5f;                 break;
            }
            fDirty = true;
        }
        else if (index == kParamMaster)
        {
            fMasterDb = clamp(value, kMinDb, kMaxDb);
            fDirty = true;
        }
    }

    // ---------------- Lifecycle ----------------

    void activate() override
    {
        for (uint32_t c = 0; c < kChannels; ++c)
        {
            fStereo[c]  = false;
            fMeter[c]   = 0.0f;
            fMeterDb[c] = kMinDb;
        }
        fMeterL = fMeterR = 0.0f;
        fMeterDbL = fMeterDbR = kMinDb;
        fDecayFrames = 0;
        updateTargets();
        resetRamps();
    }

    // ---------------- DSP ----------------

    void run(const float** inputs, float** outputs, uint32_t frames) override
    {
        if (frames == 0)
            return;

        if (frames != fDecayFrames)
        {
            // Only when the block size changes (practically: once).
            fDecayFrames = frames;
            fDecay = std::exp(-static_cast<float>(frames) / (static_cast<float>(getSampleRate()) * kMeterFall));
        }

        // ---- per-channel analysis: peaks + auto-mono detection ----
        for (uint32_t c = 0; c < kChannels; ++c)
        {
            const float* const inL = inputs[2 * c];
            const float* const inR = inputs[2 * c + 1];
            float pL = 0.0f, pR = 0.0f;
            for (uint32_t f = 0; f < frames; ++f)
            {
                pL = std::fmax(pL, std::fabs(inL[f]));
                pR = std::fmax(pR, std::fabs(inR[f]));
            }

            if (pR > 0.0f && ! fStereo[c])
            {
                fStereo[c] = true;
                fDirty = true;
            }

            fMeter[c]   = std::fmax(std::fmax(pL, pR), fMeter[c] * fDecay);
            fMeterDb[c] = toDb(fMeter[c]);
        }

        if (fDirty)
            updateTargets();

        // ---- per-block linear gain ramps (zipper-free knob moves) ----
        const float invFrames = 1.0f / static_cast<float>(frames);
        float stepL[kChannels], stepR[kChannels];
        bool  active[kChannels];
        for (uint32_t c = 0; c < kChannels; ++c)
        {
            stepL[c]  = (fTargetL[c] - fCurL[c]) * invFrames;
            stepR[c]  = (fTargetR[c] - fCurR[c]) * invFrames;
            active[c] = fCurL[c] != 0.0f || fCurR[c] != 0.0f
                     || fTargetL[c] != 0.0f || fTargetR[c] != 0.0f;
        }

        // ---- mix in stack-sized chunks: safe even if the host aliases
        //      an output buffer onto an input buffer (LV2 allows it) ----
        float* const outL = outputs[0];
        float* const outR = outputs[1];
        float accL[kChunk], accR[kChunk];
        float pkL = 0.0f, pkR = 0.0f;

        for (uint32_t off = 0; off < frames; off += kChunk)
        {
            const uint32_t n = frames - off < kChunk ? frames - off : kChunk;
            std::memset(accL, 0, sizeof(float) * n);
            std::memset(accR, 0, sizeof(float) * n);

            for (uint32_t c = 0; c < kChannels; ++c)
            {
                if (! active[c])
                    continue;
                const float* const inL = inputs[2 * c] + off;
                const float* const inR = (fStereo[c] ? inputs[2 * c + 1] : inputs[2 * c]) + off;
                float gL = fCurL[c] + stepL[c] * static_cast<float>(off);
                float gR = fCurR[c] + stepR[c] * static_cast<float>(off);
                const float sL = stepL[c], sR = stepR[c];
                for (uint32_t f = 0; f < n; ++f)
                {
                    accL[f] += inL[f] * gL;
                    accR[f] += inR[f] * gR;
                    gL += sL;
                    gR += sR;
                }
            }

            for (uint32_t f = 0; f < n; ++f)
            {
                outL[off + f] = accL[f];
                outR[off + f] = accR[f];
                pkL = std::fmax(pkL, std::fabs(accL[f]));
                pkR = std::fmax(pkR, std::fabs(accR[f]));
            }
        }

        for (uint32_t c = 0; c < kChannels; ++c)
        {
            fCurL[c] = fTargetL[c];
            fCurR[c] = fTargetR[c];
        }

        fMeterL   = std::fmax(pkL, fMeterL * fDecay);
        fMeterR   = std::fmax(pkR, fMeterR * fDecay);
        fMeterDbL = toDb(fMeterL);
        fMeterDbR = toDb(fMeterR);
    }

private:
    static float clamp(float v, float lo, float hi)
    {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    static float dbToLin(float db)
    {
        // Fader floor is "off", not -60 dB.
        return db <= kMinDb ? 0.0f : std::pow(10.0f, db * (1.0f / 20.0f));
    }

    static float toDb(float lin)
    {
        if (lin <= 0.001f) // -60 dB
            return kMinDb;
        const float db = 20.0f * std::log10(lin);
        return db > kMaxDb ? kMaxDb : db;
    }

    // Runs only when a knob or a channel's mono/stereo state changed.
    void updateTargets()
    {
        fDirty = false;
        const float master = dbToLin(fMasterDb);
        for (uint32_t c = 0; c < kChannels; ++c)
        {
            const float g = fMute[c] ? 0.0f : dbToLin(fGainDb[c]) * master;
            const float p = fPan[c];
            float pl, pr;
            if (fStereo[c])
            {
                // Balance: centre is unity on both sides.
                pl = p > 0.0f ? 1.0f - p : 1.0f;
                pr = p < 0.0f ? 1.0f + p : 1.0f;
            }
            else
            {
                // Constant-power pan for a mono source (-3 dB at centre).
                const float theta = (p + 1.0f) * 0.5f * kHalfPi;
                pl = std::cos(theta);
                pr = std::sin(theta);
            }
            fTargetL[c] = g * pl;
            fTargetR[c] = g * pr;
        }
    }

    void resetRamps()
    {
        for (uint32_t c = 0; c < kChannels; ++c)
        {
            fCurL[c] = fTargetL[c];
            fCurR[c] = fTargetR[c];
        }
    }

    // Parameters
    float fGainDb[kChannels];
    float fPan[kChannels];
    bool  fMute[kChannels];
    float fMasterDb = 0.0f;
    bool  fDirty = true;

    // DSP state
    bool     fStereo[kChannels];
    float    fTargetL[kChannels], fTargetR[kChannels];
    float    fCurL[kChannels],    fCurR[kChannels];

    // Meters (linear envelope + dB value exposed on the output ports)
    float    fMeter[kChannels];
    float    fMeterDb[kChannels];
    float    fMeterL = 0.0f, fMeterR = 0.0f;
    float    fMeterDbL = kMinDb, fMeterDbR = kMinDb;
    float    fDecay = 0.0f;
    uint32_t fDecayFrames = 0;

    DISTRHO_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR(SysMixerPlugin)
};

// ---------------------------------------------------------------------------

Plugin* createPlugin()
{
    return new SysMixerPlugin();
}

END_NAMESPACE_DISTRHO
