# RPM Oscillator

**RPM (Recursive Phase Modulation)** - Feedback FM synthesis based on Norio Tomisawa's 1981 Yamaha patent.

## Background

Based on [US Patent 4,249,447](https://patents.google.com/patent/US4249447) - "Tone production method for an electronic musical instrument" filed by Nippon Gakki (Yamaha) in 1979.

The fundamental equation:

```
x[n] = sin(ω·n + β·x[n-1])
```

As β increases from 0 toward ~1.5, the waveform morphs from a pure sine into a harmonically rich sawtooth-like wave.

[Interactive graph on Desmos →](https://www.desmos.com/calculator/vdh1xguosi)

## Hunting Filter

At high modulation indices (β > ~1.0), the feedback loop enters limit cycle oscillation at Nyquist frequency - the "hunting" ([ハンチング](https://www.nihongomaster.com/japanese/dictionary/word/9039/hanchingu-ハンチング), *hanchingu*) phenomenon. Tomisawa's solution: a 2-point moving average filter in the feedback path:

```
y_avg = 0.5 * (y[n-1] + y[n-2])
```

This acts as a Nyquist notch filter, suppressing the artifact.

## Usage

```faust
dfl = library("rpm.lib");

// Sawtooth-like (all harmonics)
process = dfl.saw(freq, beta);

// Square-like (odd harmonics)
process = dfl.sqr(freq, beta);
```

Parameters:
- `freq` - frequency in Hz
- `beta` - modulation depth (0 to ~1.5)

Note: At high beta values (~1.5), the square wave can exhibit aliasing artifacts. For cleaner results, use 2x or 4x oversampling.

## Build

```bash
faust2jaqt rpm.dsp        # JACK Qt GUI
faust2webaudio rpm.dsp    # Web Audio
faust2vst rpm.dsp         # VST plugin
```

## References

- [Tomisawa Patent (US 4,249,447)](https://patents.google.com/patent/US4249447)
- [Variations of FM](https://ristoid.net/modular/fm_variants.html) - bifurcation diagrams
- [US 6,410,838](https://patents.google.com/patent/US6410838) - squared feedback for square waves
