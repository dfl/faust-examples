// twin_osc.dsp
// TwinOsc - example code
//
// Based on: "Virtual Analog Synthesis with a Time-Varying Comb Filter"
// D. Lowenfels, AES Convention 115, October 2003
// https://www.researchgate.net/publication/325654284
//
// A sawtooth oscillator fed through a modulated comb filter (delay line)
// creates classic analog effects:
//   PWM:    Feedforward comb -> pulse width modulation
//   Morph:  Scaled feedforward -> saw to square morphing
//   Detune: Ramping delay -> pitch-shifted intervals (just intonation)

declare name "TwinOsc";
declare author "David Lowenfels";
declare version "1.0";
declare reference "https://www.researchgate.net/publication/325654284";

// Build:
//   faust2jaqt twin_osc.dsp       # JACK Qt GUI
//   faust2webaudio twin_osc.dsp   # Web Audio
//   faust2vst twin_osc.dsp        # VST plugin

import("stdfaust.lib");
dfl = library("twin_osc.lib");

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
//   Morph:  saw->square blend (0 = saw, 1 = square)
//   Detune: just intonation ratio (0=unison, 0.33=fourth, 0.5=fifth, 1=octave)
mode = hgroup("[1]Mode/Amount",
    hslider("[0]Mode[style:menu{'PWM':0;'Morph':1;'Detune':2}][tooltip:PWM=pulse width mod, Morph=saw-square blend, Detune=pitch interval]",
        0, 0, 2, 1));

amount = hgroup("[1]Mode/Amount",
    hslider("[1]Amount[style:knob][tooltip:PWM: pulse width. Morph: blend. Detune: 0=1:1, 0.33=4:3, 0.5=3:2, 1=2:1]",
        0.5, 0.0, 1.0, 0.01)) : si.smoo;

// --- PWM Vibrato (only active in PWM mode) ---
vibrato = hgroup("[2]PWM Vibrato",
    hslider("[0]Vibrato[style:knob][tooltip:PWM pulse width modulation depth/rate]",
        0, 0, 1, 0.01));

isPWM = mode < 0.5;
vibratoActive = select2(isPWM, 0, vibrato);
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
mod_amount = amount + lfo * lfoDepth * 0.5 : max(0) : min(1);

//=============================================================================
// Oscillator
//=============================================================================

// PWM and Morph use the comb filter oscillator
pwm_morph_out = dfl.twin_osc(freq, mod_amount, 0, mode);

// Detune: pitch shift via Doppler effect
osc_source = os.sawtooth(freq);
ratio = 1 + amount;
osc_shifted = osc_source : dfl.doppler_shift(freq, ratio);
detune_out = (osc_source + osc_shifted) * 0.707;

// Mode selection
isDetune = mode > 1.5;
output = select2(isDetune, pwm_morph_out, detune_out);

//=============================================================================
// Process
//=============================================================================

process = output * level <: _, _;

// Passthrough effect for poly DSP compatibility
effect = _, _;
