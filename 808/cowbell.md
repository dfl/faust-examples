# TR-808 Cowbell Implementation

Based on Werner, Abel & Smith, "More Cowbell: A Physically-Informed, Circuit-Bendable, Digital Model of the TR-808 Cowbell", AES 2014.

## Circuit Overview (Fig. 1-2)

```
┌─────────────┐    ┌───────────┐    ┌─────────┐    ┌─────────────┐
│ Oscillator 1│───▶│           │───▶│         │───▶│             │
│   540 Hz    │    │ Swing VCA │    │ Bandpass│    │ Level/Buffer│───▶ Out
│ Oscillator 2│───▶│           │───▶│ Filter  │    │             │
│   800 Hz    │    └─────┬─────┘    └─────────┘    └─────────────┘
└─────────────┘          │
                   ┌─────┴─────┐
                   │ Envelope  │◀── Trigger
                   │ Generator │
                   └───────────┘
```

## §3 Schmitt Trigger Oscillators

Two rectangular wave oscillators using HD14584 Hex Schmitt Inverter.

**Electrical characteristics** (at 25°C, VDD=5V):
- VOL = 0V (low output)
- VOH = 5V (high output)
- VT+ = 2.7V (positive threshold)
- VT- = 2.1V (negative threshold)

**Duty cycle** (Eq. 5):
```
D = ln((VOH-VT-)/(VOH-VT+)) / ln(((VOH-VT-)(VOL-VT+))/((VOH-VT+)(VOL-VT-)))
D = 0.4798 (not 50%!)
```

**Stock frequencies**:
- Oscillator 1: 540 Hz (C5+55 cents)
- Oscillator 2: 800 Hz (G5+35 cents)
- Ratio: out-of-tune perfect 5th (6.80 semitones)

## §5 Envelope Generator

Two-stage decay from coupled capacitors C9 and C34.

**Component values**:
- C9 = 0.47µF, C34 = 1µF
- R82 = 33kΩ
- R28 = R29 = 100kΩ
- R122 = 1kΩ

**Behavior**:
- Sharp attack (diode conducts when Vtrig > Venv + 0.6V)
- Two-stage decay from coupled RC networks
- Accent affects both peak amplitude AND decay time (Fig. 3)

**Simplified ODE** (Eqs. 10-12):
```
dVenv/dt = (terms involving VVCA, V, Venv, Vtrig)
dV/dt = Venv/(R82·C34) - V/(R82·C34)
```

## §6 Swing-Type VCAs

The VCA output swings between upper and lower "edge" voltages that track the envelope.

### Biasing (§6.1)
- High-pass cutoff: fc = 5.273 Hz
- Passband attenuation: G = -28.59 dB
- Bias voltage: Vbias = 0.4455V

### Edge Functions (§6.2, Table 1)

**Upper edge** (Eq. 14) - nearly linear:
```
VupperEdge = α₃·Venv + α₄
          = 1.011·Venv - 0.03122
```

**Lower edge** (Eq. 13) - complex exponential:
```
VlowerEdge = α₀·e^(-β₀·Venv^γ₀) + α₁·e^(-β₁·Venv^γ₁) + α₂
```

**Fitted coefficients** (Table 1):

| i | αᵢ | βᵢ | γᵢ |
|---|-------|--------|---------|
| 0 | 14.97 | 0.01837| -0.3179 |
| 1 | -0.01872 | 1.813 | -2.988 |
| 2 | -14.33 | | |
| 3 | 1.011 | | |
| 4 | -0.03122 | | |

**Behavior** (Fig. 4):
- Upper edge tracks envelope (~1:1)
- Lower edge stays near 0V (slight positive bias)
- Creates asymmetric positive swing
- Transistor saturation adds soft clipping

## §7 Bandpass Filter

4th-order active bandpass filter.

**Component values**:
- R24 = 2.2kΩ, R25 = 470kΩ, R26 = R27 = 10kΩ
- C28 = 10nF, C29 = 3.3nF
- C30 = C31 = 2.2nF

**Transfer function** (Eq. 15):
```
Hbp1(s) = (β₃s³ + β₂s²) / (α₄s⁴ + α₃s³ + α₂s² + α₁s + α₀)
```

Where coefficients are products of R and C values (see paper for full expansion).

**Magnitude response** (Fig. 5):
- Bandpass centered around oscillator frequencies
- ~40dB attenuation at 100Hz and 10kHz

## §8 Level Control

Simple level pot with DC blocking.

**Transfer function** (Eq. 16):
```
Hle(s) = (β₂s²) / (α₂s² + α₁s + α₀)
```

## Implementation Notes

### The stock path: Werner's model, in volts
- Schmitt oscillators at 540 / 800 Hz, 0..5 V, 48% duty, alias-suppressed (`os.pulsetrain`)
- Trigger: a 1 ms pulse of the accent level, Vct = 7 V (velocity 0) .. 14 V (velocity 1)
- Envelope: Eqs. 10-12 with the service notes' parts (C9 0.47µF, C34 1µF, R82 33k), forward Euler
- Swing VCAs on Werner's fitted edges (Table 1); accent changes the decay's shape as well as its height
- Band pass: Eq. 15 by the bilinear transform; level stage: the two coupling high passes (12 Hz, 330 Hz)

Beyond the paper, where the model needs it:
- Below the fit's range (0.5 V of envelope) the swing fades out by 0.4 V
- The collectors only draw current from C9 (D3 / D4)
- The VCAs' input stage (§6.1: 5.273 Hz, -28.59 dB, 0.4455 V bias) is not needed: the edges model the output

### Measured (one hit at full accent, 44.1 kHz)

| | 540 Hz re 800 Hz | to -20 dB | to -60 dB |
|---|---|---|---|
| this model | -15.7 dB | 160 ms | 339 ms |
| a real 808 (recording) | -15.2 dB | 127 ms | 459 ms |
| the service notes | | 50 ms to a tenth (peak to peak) | |

### Mods (each at the stock circuit by default)
- `decay x`: scales R82, R28 and R29
- `drive`: tanh on the VCAs' outputs (0 = off)
- `osc balance`: 0.5 both oscillators at full
- `env detune`: the envelope bends both oscillators up (cents at 8 V)
- `duty mod`: accent shifts the duty cycle (supply sag)
- `edge bias`: accent widens the VCAs' swing
- `keytrack`: MIDI pitch retunes the pair, keeping 800/540
- `miller lowpass`: a lowpass (15 kHz, down to 10 kHz) darkening loud hits
- `cap recovery`: quick retriggers come out weaker (400 ms recharge)

## References

Werner, K.J., Abel, J.S., & Smith, J.O. (2014). "More Cowbell: A Physically-Informed, Circuit-Bendable, Digital Model of the TR-808 Cowbell." AES 137th Convention, Los Angeles.

Companion page: https://ccrma.stanford.edu/~kwerner/papers/AES14.html
