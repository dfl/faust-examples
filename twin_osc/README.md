# TwinOsc

Twin Oscillator demonstrating classic comb filter tricks.

Based on: **"Virtual Analog Synthesis with a Time-Varying Comb Filter"**
D. Lowenfels, AES Convention 115, October 2003
https://www.researchgate.net/publication/325654284

## Overview

TwinOsc feeds an antialiased sawtooth oscillator through a modulated feedforward comb filter (delay line) to create classic analog effects:

```
y[n] = x[n] - g * x[n - d]
```

Where `d` is the delay time and `g` is the gain coefficient.

## Modes

| Mode | Comb Config | Effect |
|------|-------------|--------|
| **PWM** | `y = x - x[d]` | Pulse width modulation. Delay = fraction of period. |
| **Morph** | `y = x - g*x[d]` | Saw → square morphing. `g` controls blend. |
| **Detune** | `y = x + x[d]` | Pitch-shifted interval via ramping delay. |

## Controls

### Oscillator
- **Frequency**: Base oscillator frequency (20-2000 Hz, log scale)

### Mode/Amount
- **Mode**: Select PWM, Morph, or Detune
- **Amount**: Mode-dependent parameter
  - PWM: Pulse width (0.5 = square wave)
  - Morph: Saw/square blend (0 = saw, 1 = square)
  - Detune: Just intonation interval (0 = unison, 0.33 = 4th, 0.5 = 5th, 1 = octave)

### PWM Vibrato
- **Vibrato**: Combined rate/depth control (only active in PWM mode)
  - Couples faster rate with thicker depth
  - Range: 1-8 Hz, 0-50% depth
  - Triangle LFO shape (classic PWM)

### Output
- **Level**: Output volume

## Technical Details

### PWM Mode
Classic pulse width modulation using a feedforward comb filter. The delay time is set as a fraction of the oscillator period, creating variable duty cycle pulses.

### Morph Mode
Crossfades between sawtooth and square wave by scaling the delayed signal. At `g=0`, pure sawtooth. At `g=1`, the comb creates a square wave.

### Detune Mode
Pitch shifting via continuously ramping delay (granular approach):
- Two overlapping delay taps offset by 0.5
- Triangular crossfade windows for glitch-free wraparound
- Grain size synced to oscillator period for phase-coherent crossfades
- Just intonation mapping: ratio = 1 + amount (clean integer ratios)

The delay ramp rate determines the pitch shift:
```
ratio = 1 + amount           // 1.0 to 2.0 (unison to octave)
ramp_rate = (ratio - 1) / grain_size
```

## Files

- `twin_osc.dsp` - Main Faust DSP file with GUI controls
- `twin_osc.lib` - Library with core oscillator and comb filter functions

## License

See parent project license.
