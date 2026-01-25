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
- C9 = 0.47µF, C34 = 0.47µF
- R82 = 82kΩ
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
- R24 = R25 = R26 = R27 = 10kΩ
- C28 = C30 = 2.2nF
- C29 = 3.3nF
- C31 = 10nF

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

### What we implemented:
- ✓ Schmitt oscillators with 48% duty cycle
- ✓ Two-stage coupled envelope decay
- ✓ Werner's exact VCA edge curves (Table 1)
- ✓ 5.3 Hz highpass bias filter
- ✓ 4th-order bandpass from component values
- ✓ Accent affects amplitude + decay time
- ✓ tanh soft clipping for transistor saturation

### What we added (not in Werner):
- Capacitor recovery model for retrigger "choking"
- Miller effect (dynamic lowpass 10-15kHz)
- MIDI velocity → accent mapping
- MIDI pitch → oscillator tuning (maintains ratio)
- Adjustable drive parameter

## References

Werner, K.J., Abel, J.S., & Smith, J.O. (2014). "More Cowbell: A Physically-Informed, Circuit-Bendable, Digital Model of the TR-808 Cowbell." AES 137th Convention, Los Angeles.

Companion page: https://ccrma.stanford.edu/~kwerner/papers/AES14.html
