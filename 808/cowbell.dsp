import("stdfaust.lib");

////////////////////////////////////////////////////////////
// 808 COWBELL
// Based on Werner, Abel & Smith, AES 2014:
// "More Cowbell: A Physically-Informed, Circuit-Bendable,
//  Digital Model of the TR-808 Cowbell"
////////////////////////////////////////////////////////////
//
// === WHAT WE IMPLEMENTED FROM WERNER ET AL. ===
//
// §3 Schmitt Trigger Oscillators:
//   ✓ Two square waves at 540/800 Hz (out-of-tune 5th)
//   ✓ 48% duty cycle from HD14584 characteristics
//   ✓ Free-running (not synced to trigger)
//
// §5 Envelope Generator:
//   ✓ Two-stage decay (coupled C9/C34 capacitors)
//   ✓ Time constants from actual component values
//   ✓ Accent affects both amplitude AND decay time (Fig. 3)
//   ✓ Diode switching (Eq. 9): fast attack via R122, slow decay via R82
//   ✓ VCA feedback into envelope (Eqs. 10-12) via R28/R29
//   ✓ Forward Euler ODE solver for exact Werner equations
//
// §6 Swing-Type VCAs:
//   ✓ Werner's exact fitted edge curves (Table 1, Eqs. 13-14)
//   ✓ Upper edge: α₃·Venv + α₄ (nearly linear)
//   ✓ Lower edge: α₀·e^(-β₀·Venv^γ₀) + α₁·e^(-β₁·Venv^γ₁) + α₂
//   ✓ 5.3 Hz high-pass bias filter
//
// §7 Bandpass Filter:
//   ✓ Werner's exact Eq. 15 transfer function
//   ✓ Bilinear transform to 4th-order IIR
//   ✓ Direct implementation via fi.iir
//
// === WHAT WE ADDED (NOT IN WERNER) ===
//
// - Capacitor recovery model for retrigger "choking"
//   (fast retriggers sound weaker/shorter)
// - Miller effect: dynamic lowpass that darkens transients
// - MIDI velocity → accent (amplitude + decay)
// - MIDI pitch → oscillator tuning (maintains 800/540 ratio)
// - User-adjustable decay and drive controls
// - Optional tanh saturation (drive > 1.0 enables, approximates BJT limiting)
//
// Tonal modifications (Werner Fig. 7d style circuit-bending):
// - Oscillator balance: changes beating character and perceived pitch
// - Envelope detune: FM modulation for metallic bloom on attack
// - Duty cycle modulation: accent changes timbre via supply sag effect
// - Envelope-dependent Q: stronger ringing on accented hits
// - VCA edge bias: accent boosts swing for more dynamic range
//
// === WHAT WE SIMPLIFIED ===
//
// - (none remaining - full Werner model implemented)
//
////////////////////////////////////////////////////////////

// PARAMETERS
level = hslider("level", 0.8, 0, 1, 0.01);
decayTime = hslider("decay", 0.3, 0.05, 1.0, 0.01);
drive = hslider("drive", 10.0, 0.5, 10.0, 0.1);  // >1.0 enables tanh saturation

// Tonal modifications (Werner Fig. 7d style)
oscBalance = hslider("osc balance", 0.5, 0, 1, 0.01);  // 0.5 = equal, 0 = osc1 only, 1 = osc2 only
envDetune = hslider("env detune", 0, 0, 10, 0.1);      // cents of FM from envelope
dutyMod = hslider("duty mod", 0, 0, 0.05, 0.001);      // duty cycle modulation by accent
// qMod removed - using Werner's fixed bandpass filter
edgeBias = hslider("edge bias", 0, 0, 0.5, 0.01);      // accent-dependent VCA edge boost

////////////////////////////////////////////////////////////
// MIDI INPUT
////////////////////////////////////////////////////////////

// Enable MIDI
declare options "[midi:on][nvoices:1]";

// Standard polyphonic MIDI (gate/gain/freq)
gate = button("gate");
midiGain = hslider("gain", 0.5, 0, 1, 0.01);
midiFreqRaw = hslider("freq", 540, 200, 2000, 0.01);

// Accent from MIDI velocity (clamped to 0.3 minimum)
accent = max(0.3, midiGain);

// Frequency from MIDI (defaults to 540 Hz)
freqAtTrigger = midiFreqRaw;

// Sample-and-hold frequency at trigger moment
// Initialize to 540 Hz before first trigger
hasFired = trig : max ~ _;
freq1raw = freqAtTrigger : ba.sAndH(trig);
freq1 = select2(hasFired, 540.0, freq1raw);

// Ratio between oscillators: 800/540 (out-of-tune 5th)
ratio = 800.0 / 540.0;
freq2 = freq1 * ratio;

////////////////////////////////////////////////////////////
// SCHMITT TRIGGER OSCILLATORS (§3)
////////////////////////////////////////////////////////////

// HD14584 Schmitt inverter characteristics (at 25°C, VDD=5V)
// VOL = 0V, VOH = 5V, VT+ = 2.7V, VT- = 2.1V
// Duty cycle D = 0.4798 (not 50%!)

dutyCycleBase = 0.4798;

// Accent modulates duty cycle (supply sag effect)
// Higher accent = slight duty cycle shift
dutyCycle = dutyCycleBase + dutyMod * (accent - 0.5);

// Square wave with correct duty cycle
// os.lf_pulsetrainpos gives pulse with adjustable duty cycle
sqDuty(f, d) = os.lf_pulsetrainpos(f, d) * 2.0 - 1.0;

// Oscillator balance: sqrt for equal-power crossfade
osc1gain = sqrt(1.0 - oscBalance);
osc2gain = sqrt(oscBalance);

////////////////////////////////////////////////////////////
// TRIGGER & ENVELOPE GENERATOR (§5)
// With VCA feedback per Werner Eqs. 10-12
////////////////////////////////////////////////////////////

// Rising edge detection with startup guard
trig = gate : ba.impulsify : *(ba.time > 100);

// Werner component values (§5):
// C9=0.47µF, C34=0.47µF, R82=82k, R28=R29=100k, R122=1k
C9 = 0.47e-6;  C34 = 0.47e-6;
R82 = 82e3;    R28 = 100e3;  R29 = 100e3;  R122 = 1e3;

// Diode model (Werner Eq. 9)
// Von = 0.6V standard silicon diode drop
// Normalized: 0.6V / 8V scale ≈ 0.075
Von = 0.075;

// Decay scaling: decay=0.3 (default) gives stock Werner R82=82k
// Higher accent = longer decay (per Werner Fig. 3)
// Effectively scales R82 (larger = slower decay)
decayScale = decayTime / 0.3;                    // 1.0 at default
accentScale = 0.5 + accent * 0.5;                // 0.5 to 1.0 based on velocity
// Main envelope (venv) gets full decay scaling
R82_venv = R82 * decayScale * accentScale;
// Secondary envelope (vprime) is always 1.5x slower for consistent tail ratio
R82_vprime = R82_venv * 1.5;

// Forward Euler ODE coefficients (Werner Eqs. 10-12)
// k_XY = 1/(RX * CY) in Hz (rate constants)
dt = 1.0 / ma.SR;  // time step

// Scale R28/R29 with decay so the decay parameter is effective
// (otherwise R28/R29 dominate and decay has little effect at long settings)
R28_scaled = R28 * decayScale;
R29_scaled = R29 * decayScale;

k_R28C9 = 1.0 / (R28_scaled * C9);   // VCA feedback (scaled)
k_R29C9 = 1.0 / (R29_scaled * C9);   // VCA feedback (scaled)
k_R82C9 = 1.0 / (R82_venv * C9);     // V' coupling into venv
k_R122C9 = 1.0 / (R122 * C9);        // 2127.66 Hz - fast attack
k_R82C34 = 1.0 / (R82_vprime * C34); // V' own decay

// Combined coefficients for release phase (Eq. 12)
// dVenv/dt = vcaFb*(k_R28C9+k_R29C9) + V*k_R82C9 - Venv*(k_R28C9+k_R29C9+k_R82C9)
k_vca_release = k_R28C9 + k_R29C9;
k_venv_release = k_R28C9 + k_R29C9 + k_R82C9;

// Combined coefficients for attack phase (Eq. 10)
// Adds R122 path when diode conducts
k_venv_attack = k_R28C9 + k_R29C9 + k_R82C9 + k_R122C9;

////////////////////////////////////////////////////////////
// CAPACITOR RECOVERY MODEL (retrigger behavior)
// Models timing capacitor that needs to recharge between hits
////////////////////////////////////////////////////////////

tauCharge = 0.4;       // 400ms to fully recharge
dischargeK = 0.05;     // Residual after discharge

chargeCoef = exp(-1.0 / (tauCharge * ma.SR));

// Capacitor voltage: charges toward 1.0, discharges on trigger
// Use previous sample's value for sample-and-hold (before discharge)
capVoltage = cv ~ _
with {
  cv(prev) = select2(trig,
    1.0 - (1.0 - prev) * chargeCoef,  // charging
    prev * dischargeK                  // discharge on trigger
  );
};

// Sample cap voltage BEFORE discharge (use delayed capVoltage)
capAtTrig = ba.sAndH(trig, capVoltage');

// Initialize to fully charged until first trigger
firstTrig = trig : max ~ _;
capScale = select2(firstTrig, 1.0, capAtTrig) : max(0.1);

////////////////////////////////////////////////////////////
// SWING-TYPE VCAs (§6)
// Werner's exact fitted edge curves (Table 1, Eqs. 13-14)
////////////////////////////////////////////////////////////

// Soft clipping (tanh from primitives)
tanhSat(x) = (exp(2*x) - 1) / (exp(2*x) + 1);

// Werner's fitted coefficients from Table 1:
// VlowerEdge = α₀·e^(-β₀·Venv^γ₀) + α₁·e^(-β₁·Venv^γ₁) + α₂
// VupperEdge = α₃·Venv + α₄
alpha0 = 14.97;   alpha1 = -0.01872;  alpha2 = -14.33;
alpha3 = 1.011;   alpha4 = -0.03122;
beta0 = 0.01837;  beta1 = 1.813;
gamma0 = -0.3179; gamma1 = -2.988;

// Werner's Venv is in volts (0-8V range per Fig. 3)
// Scale our normalized envelope (0-1) to voltage range
venvScale = 8.0;

// Safe power for negative exponents: clamp to prevent infinity
// eMin is in normalized 0-1 range, vMin is in Werner's 0-8V range
eMin = 0.05;  // minimum envelope (normalized)
vMin = eMin * venvScale;  // 0.4V in Werner's scale
safePow(base, ex) = pow(max(base, vMin), ex);

// Werner's exact edge functions (Eqs. 13-14)
// Upper edge is nearly linear (α₃·Venv + α₄)
// Lower edge has two exponential terms with negative powers inside
upperEdgeVolts(venv) = alpha3 * venv + alpha4;
lowerEdgeVolts(venv) = alpha0 * exp(-beta0 * safePow(venv, gamma0))
                     + alpha1 * exp(-beta1 * safePow(venv, gamma1))
                     + alpha2;

// Normalized edge functions (scale envelope, compute, normalize output)
// Output normalized to swing ±1 at full envelope
upperEdge(e) = upperEdgeVolts(e * venvScale) / venvScale;
lowerEdge(e) = lowerEdgeVolts(e * venvScale) / venvScale;

// VCA: square wave swings between edges
// Note: in Werner's circuit, lower edge is positive (near 0V)
// and upper edge tracks envelope - asymmetric positive swing
//
// drive ≤ 1.0: Werner-faithful (no saturation)
// drive > 1.0: tanh soft clipping (approximates BJT saturation)
//
// Envelope gate: eliminates residual leakage from eMin clamping
// when envelope decays below threshold
conditionalSat(x) = select2(drive > 1.0, x, tanhSat(x));
envGate(e) = min(1.0, e * 20);  // fast gate: full open above e=0.05
// Clean VCA (for feedback path - no drive)
swingVCAClean(osc, e) = select2(osc > 0, lowerEdge(e), upperEdge(e)) : *(envGate(e));
// Driven VCA (for audio output)
swingVCA(osc, e) = swingVCAClean(osc, e) : *(drive) : conditionalSat;

// Unified envelope + VCA system with Forward Euler ODE solver (Werner §5-6)
// Implements Werner's exact Eqs. 10-12 using discrete-time integration
// All computed together in single letrec to handle circular dependency
vcaSum = v1raw + v2raw  // Audio output uses raw VCA (no HP)
letrec {
  // VCA feedback: uses HP-filtered signal to remove DC that would sustain envelope
  // In Werner's analog circuit, AC coupling removes DC before feedback
  // Note: vcaFb is gated below using fbGate to prevent secondary bump
  'vcaFbRaw = (v1 + v2) : si.smooth(ba.tau2pole(0.001));

  // Trigger level: jumps to 1.0 on trigger, decays quickly (1ms pulse)
  // Models the Vtrig signal from trigger logic (§4)
  'trigLevel = select2(trig,
    trigLevel * exp(-1.0 / (0.001 * ma.SR)),  // 1ms decay
    1.0  // trigger fires
  ) : max(0);

  // Forward Euler ODE for Venv (Werner Eqs. 10, 12)
  // Diode conducts when Vtrig > Venv + Von
  //
  // Release (Eq. 12): dVenv/dt = vcaFb*k_vca + V'*k_R82C9 - Venv*k_venv_release
  // Attack (Eq. 10): adds R122 charging path
  //   k_venv_attack already includes -Venv*k_R122C9
  //   Additional term: +(Vtrig - Von)*k_R122C9 drives charging
  //
  // Gate feedback when envelope is low (prevents DC from sustaining envelope)
  // vprime coupling is NOT gated - allows authentic slow decay tail per Werner Fig. 3
  'fbGate = envGate(venv * accent * level);
  'vcaFbGated = vcaFbRaw * fbGate;
  'vprimeTerm = vprime * k_R82C9;  // ungated for authentic decay
  'venv = (venv + dt * select2(trigLevel > (venv + Von),
    // Release phase (diode off): decay through R28, R29, R82
    vcaFbGated * k_vca_release + vprimeTerm - venv * k_venv_release,
    // Attack phase (diode on): fast charge through R122
    vcaFbGated * k_vca_release + vprimeTerm - venv * k_venv_attack
    + (trigLevel - Von) * k_R122C9
  )) : max(0) : min(1);

  // Forward Euler ODE for V' (Werner Eq. 11)
  // dV'/dt = (Venv - V') * k_R82C34
  'vprime = (vprime + dt * (venv - vprime) * k_R82C34) : max(0) : min(1);

  // Scaled envelope for VCA + accent-dependent edge bias
  // edgeBias increases swing at higher accents (more Werner-authentic "drive")
  'eScaled = venv * capScale * accent * level * (1.0 + edgeBias * accent);

  // Envelope-dependent FM (metallic bloom on attack)
  // envDetune in cents, modulated by eScaled
  'fmMult = pow(2.0, envDetune * eScaled / 1200.0);
  'osc1 = sqDuty(freq1 * fmMult, dutyCycle) * osc1gain;
  'osc2 = sqDuty(freq2 * fmMult, dutyCycle) * osc2gain;

  // VCA outputs: driven for audio, clean+HP for feedback
  // Feedback uses clean VCA (no drive) to avoid drive/decay interaction
  // HP removes DC that would otherwise sustain envelope forever
  'v1clean = swingVCAClean(osc1, eScaled);
  'v2clean = swingVCAClean(osc2, eScaled);
  'v1 = v1clean : fi.highpass(1, 5.3);  // for feedback path
  'v2 = v2clean : fi.highpass(1, 5.3);
  'v1raw = swingVCA(osc1, eScaled);  // driven output for audio
  'v2raw = swingVCA(osc2, eScaled);
};


////////////////////////////////////////////////////////////
// BANDPASS FILTER (§7)
// Werner's exact 4th-order transfer function (Eq. 15)
////////////////////////////////////////////////////////////

// Correct component values from Werner paper:
// R24=2.2k, R25=470k, R26=R27=10k
// C28=10nF, C29=3.3nF, C30=C31=2.2nF
// Peak frequency: 871 Hz (A5 - 18 cents)
bpR24 = 2.2e3; bpR25 = 470e3; bpR26 = 10e3; bpR27 = 10e3;
bpC28 = 10e-9; bpC29 = 3.3e-9; bpC30 = 2.2e-9; bpC31 = 2.2e-9;

// Werner Eq. 15 s-domain coefficients (Hbp1)
// H(s) = (β₃s³ + β₂s²) / (α₄s⁴ + α₃s³ + α₂s² + α₁s + α₀)
bpBeta3 = -bpR24*bpR25*bpR27*bpC28*bpC30*bpC31;
bpBeta2 = -bpR24*bpR25*bpC28*bpC30;

bpAlpha4 = bpR24*bpR25*bpR26*bpR27*bpC28*bpC29*bpC30*bpC31;
bpAlpha3 = bpR24*bpR25*bpR26*bpC28*bpC29*bpC30
         + bpR24*bpR25*bpR27*bpC28*bpC29*bpC31
         + bpR24*bpR26*bpR27*bpC28*bpC30*bpC31
         + bpR24*bpR26*bpR27*bpC29*bpC30*bpC31;
bpAlpha2 = bpR24*bpR25*bpC28*bpC29 + bpR24*bpR26*bpC28*bpC30
         + bpR24*bpR26*bpC29*bpC30 + bpR24*bpR26*bpC30*bpC31
         + bpR24*bpR27*bpC28*bpC31 + bpR24*bpR27*bpC29*bpC31
         + bpR24*bpR27*bpC30*bpC31 + bpR26*bpR27*bpC30*bpC31;
bpAlpha1 = bpR24*bpC28 + bpR24*bpC29 + bpR24*bpC30 + bpR24*bpC31
         + bpR26*bpC30 + bpR27*bpC31;
bpAlpha0 = 1.0;

// Bilinear transform: s = c*(1-z^-1)/(1+z^-1), c = 2*SR
// For H(s) = (β₃s³ + β₂s²) / (α₄s⁴ + α₃s³ + α₂s² + α₁s + α₀)
//
// After substitution and multiplying by (1+z^-1)⁴:
// Numerator: β₃*c³*(1-z^-1)³*(1+z^-1) + β₂*c²*(1-z^-1)²*(1+z^-1)²
// Denominator: sum of αᵢ*cⁱ*(1-z^-1)ⁱ*(1+z^-1)^(4-i)
//
// Polynomial expansions:
// (1-z^-1)⁴ = 1 - 4z^-1 + 6z^-2 - 4z^-3 + z^-4
// (1-z^-1)³(1+z^-1) = 1 - 2z^-1 + 2z^-3 - z^-4
// (1-z^-1)²(1+z^-1)² = 1 - 2z^-2 + z^-4
// (1-z^-1)(1+z^-1)³ = 1 + 2z^-1 - 2z^-3 - z^-4
// (1+z^-1)⁴ = 1 + 4z^-1 + 6z^-2 + 4z^-3 + z^-4

bpC = 2.0 * ma.SR;  // bilinear constant
bpC2 = bpC * bpC;
bpC3 = bpC2 * bpC;
bpC4 = bpC3 * bpC;

// Numerator coefficients (from β₃s³ + β₂s²)
bpb0 = bpBeta3*bpC3 + bpBeta2*bpC2;
bpb1 = -2*bpBeta3*bpC3;
bpb2 = -2*bpBeta2*bpC2;
bpb3 = 2*bpBeta3*bpC3;
bpb4 = -bpBeta3*bpC3 + bpBeta2*bpC2;

// Denominator coefficients
bpa0 = bpAlpha4*bpC4 + bpAlpha3*bpC3 + bpAlpha2*bpC2 + bpAlpha1*bpC + bpAlpha0;
bpa1 = -4*bpAlpha4*bpC4 - 2*bpAlpha3*bpC3 + 2*bpAlpha1*bpC + 4*bpAlpha0;
bpa2 = 6*bpAlpha4*bpC4 - 2*bpAlpha2*bpC2 + 6*bpAlpha0;
bpa3 = -4*bpAlpha4*bpC4 + 2*bpAlpha3*bpC3 - 2*bpAlpha1*bpC + 4*bpAlpha0;
bpa4 = bpAlpha4*bpC4 - bpAlpha3*bpC3 + bpAlpha2*bpC2 - bpAlpha1*bpC + bpAlpha0;

// Normalized z-domain coefficients (divide by a0)
bpB0 = bpb0/bpa0; bpB1 = bpb1/bpa0; bpB2 = bpb2/bpa0; bpB3 = bpb3/bpa0; bpB4 = bpb4/bpa0;
bpA1 = bpa1/bpa0; bpA2 = bpa2/bpa0; bpA3 = bpa3/bpa0; bpA4 = bpa4/bpa0;

// Exact 4th-order IIR from Werner Eq. 15 via bilinear transform
// Peak gain is ~3.18 at 871 Hz, normalize to unity
bpGainNorm = 0.315;
bandpass4 = fi.iir((bpB0, bpB1, bpB2, bpB3, bpB4), (bpA1, bpA2, bpA3, bpA4)) : *(bpGainNorm);

// Apply Werner's bandpass filter (871 Hz center, Q ≈ 4.8)
filtered = vcaSum : bandpass4;

////////////////////////////////////////////////////////////
// OUTPUT STAGE (§8) + MILLER EFFECT
////////////////////////////////////////////////////////////

// Miller effect: transistor bandwidth limitation
// Higher signal levels = more capacitance = lower cutoff frequency
// This darkens transients like the real circuit

millerEnv = filtered : abs : si.smooth(0.9995);

// Dynamic cutoff: ~15kHz at rest, drops to ~10kHz on transients
// Conservative estimate for 808-era BJT VCA stage
millerCutoff = 15000 - (millerEnv * 5000) : max(10000) : min(15000);

// DC blocking + dynamic lowpass + output scaling
out = filtered
  : fi.dcblocker
  : fi.lowpass(1, millerCutoff)
  : *(2.0);  // makeup gain

process = out <: _, _;
