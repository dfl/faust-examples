// twin_osc.dsp
// TwinOsc - Virtual Analog Synthesis with Time-Varying Comb Filter
//
// Based on: "Virtual Analog Synthesis with a Time-Varying Comb Filter"
// D. Lowenfels, AES Convention 115, October 2003
// https://www.researchgate.net/publication/325654284
//
// A sawtooth oscillator fed through a modulated comb filter (delay line)
// creates classic analog effects:
//   PWM:    Feedforward comb → pulse width modulation
//   Morph:  Scaled feedforward → saw to square morphing
//   Detune: Ramping delay → pitch-shifted intervals (just intonation)

declare name "TwinOsc";
declare author "David Lowenfels <dfl>";
declare version "1.0";
declare reference "https://www.researchgate.net/publication/325654284";

// Build:
//   faust2jaqt twin_osc.dsp       # JACK Qt GUI
//   faust2webaudio twin_osc.dsp   # Web Audio
//   faust2vst twin_osc.dsp        # VST plugin

import("stdfaust.lib");
import("twin_osc.lib");

//=============================================================================
// Controls
//=============================================================================

// --- Oscillator ---
freq = hgroup("[0]Oscillator",
    hslider("[0]Frequency[style:knob][scale:log][unit:Hz][tooltip:Base oscillator frequency]",
        220, 20, 2000, 0.1)) : si.smoo;

// --- Mode + Amount (same row) ---
// Amount meaning depends on mode:
//   PWM:    pulse width (0.5 = square)
//   Morph:  saw→square blend (0 = saw, 1 = square)
//   Detune: just intonation ratio (0=unison, 0.33=fourth, 0.5=fifth, 1=octave)
mode = hgroup("[1]Mode/Amount",
    hslider("[0]Mode[style:menu{'PWM':0;'Morph':1;'Detune':2}][tooltip:PWM=pulse width mod, Morph=saw-square blend, Detune=pitch interval]",
        0, 0, 2, 1));

amount = hgroup("[1]Mode/Amount",
    hslider("[1]Amount[style:knob][tooltip:PWM: pulse width. Morph: blend. Detune: 0=1:1, 0.33=4:3, 0.5=3:2, 1=2:1]",
        0.5, 0.0, 1.0, 0.01)) : si.smoo;

// --- PWM Vibrato (only active in PWM mode) ---
// Single knob: faster rate + thicker depth as you turn up
vibrato = hgroup("[2]PWM Vibrato",
    hslider("[0]Vibrato[style:knob][tooltip:PWM pulse width modulation. Only active in PWM mode]",
        0, 0, 1, 0.01));

// Mode detection
isPWM = mode < 0.5;
isDetune = mode > 1.5;

// Vibrato only active in PWM mode
vibratoActive = select2(isPWM, 0, vibrato);

// PWM: 1-8 Hz rate, 0.3-0.5 depth (both increase together)
lfoRate = 1 + vibratoActive * 7;
lfoDepth = vibratoActive * 0.5;

// --- Output ---
level = hgroup("[3]Output",
    hslider("[0]Level[style:knob][tooltip:Output volume]",
        0.5, 0, 1, 0.01)) : si.smoo;

//=============================================================================
// LFO (triangle - classic PWM shape)
//=============================================================================

lfo = os.lf_triangle(lfoRate);

// LFO modulates amount for PWM (clamped to valid range)
mod_amount = amount + lfo * lfoDepth * 0.5 : max(0) : min(1);

//=============================================================================
// Mode-Dependent Processing
//=============================================================================

// PWM/Morph: delay-based comb filter
pwm_morph_out = to_twin_osc(freq, mod_amount, 0, mode);

// Detune: PITCH SHIFT via continuously modulated delay with crossfade
// Just intonation mapping: amount 0-1 → ratio 1-2
// 0 = unison, 0.333 = fourth (4/3), 0.5 = fifth (3/2), 1 = octave (2/1)
// NO LFO modulation - static pitch interval

MAX_SHIFT_DELAY = 2048;

// Use raw amount (no LFO) for clean static intervals
ratio = 1 + amount;  // Clean integer ratios at key points
delay_change_rate = ratio - 1;  // = amount, always >= 0

// Sync grain size to oscillator period for phase-coherent crossfades
// Grain = N complete oscillator cycles, so crossfade happens at same phase
period_samples = ma.SR / freq;
grain_periods = max(1, floor(MAX_SHIFT_DELAY / 2 / period_samples));  // /2 for safety margin
grain_size = min(MAX_SHIFT_DELAY, grain_periods * period_samples) : si.smoo;

ramp_rate = delay_change_rate / grain_size;

// Two phasors offset by 0.5 for overlapping grains
phasor1 = (+(ramp_rate) : ma.frac) ~ _;
phasor2 = (phasor1 + 0.5) : ma.frac;

// Delay values: grain_size→0 as phasor goes 0→1 (for pitch UP)
delay1 = max(4, (1 - phasor1) * grain_size);
delay2 = max(4, (1 - phasor2) * grain_size);

// Source oscillator
osc_source = to_saw(freq);

// Two pitch-shifted versions
shifted1 = to_hermite_delay(MAX_SHIFT_DELAY, delay1, osc_source);
shifted2 = to_hermite_delay(MAX_SHIFT_DELAY, delay2, osc_source);

// Triangular crossfade windows: peak at phasor=0.5, zero at edges
window1 = 1 - abs(2 * phasor1 - 1);
window2 = 1 - abs(2 * phasor2 - 1);

// Crossfade (windows always sum to ~1 when offset by 0.5)
osc_shifted = (shifted1 * window1 + shifted2 * window2);

// Power-preserving mix: 1/sqrt(2) ≈ 0.707 for two correlated signals
detune_out = (osc_source + osc_shifted) * 0.707;

// Select based on mode
output = select2(isDetune, pwm_morph_out, detune_out);

//=============================================================================
// Process
//=============================================================================

process = output * level <: _, _;

// Passthrough effect for poly DSP compatibility
effect = _, _;
