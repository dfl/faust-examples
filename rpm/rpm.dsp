// rpm.dsp
// RPM (Recursive Phase Modulation) Oscillator Demo
//
// Based on Norio Tomisawa's 1981 Yamaha patent (US4249447A)
// https://patents.google.com/patent/US4249447

declare name "RPM Oscillator";
declare author "David Lowenfels";
declare version "1.0";
declare reference "https://patents.google.com/patent/US4249447";

// Build:
//   faust2jaqt rpm.dsp        # JACK Qt GUI
//   faust2webaudio rpm.dsp    # Web Audio
//   faust2vst rpm.dsp         # VST plugin

import("stdfaust.lib");
dfl = library("rpm.lib");

//=============================================================================
// Controls
//=============================================================================

freq = hgroup("[0]Oscillator",
    hslider("[0]Frequency[style:knob][scale:log][unit:Hz][tooltip:Base frequency]",
        220, 20, 2000, 0.1)) : si.smoo;

beta = hgroup("[0]Oscillator",
    hslider("[1]Beta[style:knob][tooltip:Modulation depth - morphs from sine to saw/square]",
        0.5, 0, 1.5, 0.01)) : si.smoo;

shape = hgroup("[1]Shape",
    hslider("[0]Saw/Square[style:knob][tooltip:Crossfade between sawtooth and square wave]",
        0, 0, 1, 0.01)) : si.smoo;

level = hgroup("[2]Output",
    hslider("[0]Level[style:knob][tooltip:Output volume]",
        0.5, 0, 1, 0.01)) : si.smoo;

//=============================================================================
// Oscillators
//=============================================================================

saw_out = dfl.rpm.saw(freq, beta);
sqr_out = dfl.rpm.square(freq, beta);

// Crossfade between saw and square
output = saw_out * (1 - shape) + sqr_out * shape;

//=============================================================================
// Process
//=============================================================================

process = output * level <: _, _;
