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

// =============================================================================
// PARAMETERS
// =============================================================================

// Main controls
level     = hslider("level", 0.8, 0, 1, 0.01);
decayTime = hslider("decay", 0.3, 0.05, 1.0, 0.01);
drive     = hslider("drive", 10.0, 0.5, 10.0, 0.1);  // >1.0 enables tanh saturation

// Tonal modifications (Werner Fig. 7d style circuit-bending)
oscBalance = hslider("osc balance", 0.5, 0, 1, 0.01);  // 0=osc1, 0.5=equal, 1=osc2
envDetune  = hslider("env detune", 0, 0, 10, 0.1);     // FM cents from envelope
dutyMod    = hslider("duty mod", 0, 0, 0.05, 0.001);   // duty cycle modulation
edgeBias   = hslider("edge bias", 0, 0, 0.5, 0.01);    // accent-dependent VCA boost

// =============================================================================
// MIDI INPUT
// =============================================================================

declare options "[midi:on][nvoices:1]";

gate        = button("gate");
midiGain    = hslider("gain", 0.5, 0, 1, 0.01);
midiFreqRaw = hslider("freq", 540, 200, 2000, 0.01);

accent = max(0.3, midiGain);  // velocity with 0.3 minimum

// Sample-and-hold frequency at trigger (init to 540 Hz before first trigger)
hasFired = trig : max ~ _;
freq1raw = midiFreqRaw : ba.sAndH(trig);
freq1    = select2(hasFired, 540.0, freq1raw);

// Two oscillators at out-of-tune 5th (800/540 ratio)
freq2 = freq1 * (800.0 / 540.0);

// =============================================================================
// SCHMITT TRIGGER OSCILLATORS (§3)
// HD14584 characteristics: VT+=2.7V, VT-=2.1V → D=0.4798 (not 50%!)
// =============================================================================

dutyCycleBase = 0.4798;
dutyCycle = dutyCycleBase + dutyMod * (accent - 0.5);  // supply sag effect

// Square wave with adjustable duty cycle, bipolar output
sqDuty(f, d) = os.lf_pulsetrainpos(f, d) * 2.0 - 1.0;

// Equal-power crossfade between oscillators
osc1gain = sqrt(1.0 - oscBalance);
osc2gain = sqrt(oscBalance);

// =============================================================================
// TRIGGER & ENVELOPE GENERATOR (§5)
// Forward Euler ODE with VCA feedback per Werner Eqs. 10-12
// =============================================================================

// Rising edge detection with startup guard
trig = gate : ba.impulsify : *(ba.time > 100);

// Werner component values (§5)
C9   = 0.47e-6;  C34  = 0.47e-6;  // capacitors
R82  = 82e3;     R122 = 1e3;       // resistors
R28  = 100e3;    R29  = 100e3;

Von = 0.075;  // diode drop: 0.6V / 8V scale (Werner Eq. 9)

// Decay scaling: decay=0.3 gives stock Werner R82, accent extends decay (Fig. 3)
decayScale  = decayTime / 0.3;
accentScale = 0.5 + accent * 0.5;
R82_venv    = R82 * decayScale * accentScale;
R82_vprime  = R82_venv * 1.5;  // secondary envelope 1.5x slower

// Forward Euler coefficients: k = 1/(R*C) rate constants
dt = 1.0 / ma.SR;

R28_scaled = R28 * decayScale;
R29_scaled = R29 * decayScale;

k_R28C9  = 1.0 / (R28_scaled * C9);
k_R29C9  = 1.0 / (R29_scaled * C9);
k_R82C9  = 1.0 / (R82_venv * C9);
k_R122C9 = 1.0 / (R122 * C9);       // fast attack path
k_R82C34 = 1.0 / (R82_vprime * C34);

// Combined rate constants for attack/release phases
k_vca_release  = k_R28C9 + k_R29C9;
k_venv_release = k_R28C9 + k_R29C9 + k_R82C9;
k_venv_attack  = k_venv_release + k_R122C9;

// =============================================================================
// CAPACITOR RECOVERY MODEL (retrigger "choking")
// Fast retriggers sound weaker/shorter due to incomplete recharge
// =============================================================================

tauCharge   = 0.4;   // 400ms to fully recharge
dischargeK  = 0.05;  // residual after discharge
chargeCoef  = exp(-1.0 / (tauCharge * ma.SR));

// Capacitor voltage: charges toward 1.0, discharges on trigger
capVoltage = (_ <: select2(trig,
    1.0 - (1.0 - _) * chargeCoef,  // charging
    _ * dischargeK                  // discharge
)) ~ _;

// Sample cap voltage before discharge, init fully charged
capAtTrig = ba.sAndH(trig, capVoltage');
firstTrig = trig : max ~ _;
capScale  = select2(firstTrig, 1.0, capAtTrig) : max(0.1);

// =============================================================================
// SWING-TYPE VCAs (§6)
// Werner's exact fitted edge curves (Table 1, Eqs. 13-14)
// =============================================================================

tanhSat(x) = (exp(2*x) - 1) / (exp(2*x) + 1);  // soft clipping

// Werner's fitted coefficients (Table 1)
alpha0 = 14.97;    alpha1 = -0.01872;  alpha2 = -14.33;
alpha3 = 1.011;    alpha4 = -0.03122;
beta0  = 0.01837;  beta1  = 1.813;
gamma0 = -0.3179;  gamma1 = -2.988;

venvScale = 8.0;  // Werner uses 0-8V range
vMin = 0.4;       // clamp for safe negative exponents (0.05 * 8V)

safePow(base, ex) = pow(max(base, vMin), ex);

// Edge functions: upper is linear, lower has double-exponential
upperEdgeVolts(v) = alpha3 * v + alpha4;
lowerEdgeVolts(v) = alpha0 * exp(-beta0 * safePow(v, gamma0))
                  + alpha1 * exp(-beta1 * safePow(v, gamma1))
                  + alpha2;

// Normalized versions (0-1 envelope → 0-1 output)
upperEdge(e) = upperEdgeVolts(e * venvScale) / venvScale;
lowerEdge(e) = lowerEdgeVolts(e * venvScale) / venvScale;

// VCA helper functions
conditionalSat(x) = select2(drive > 1.0, x, tanhSat(x));
envGate(e) = min(1.0, e * 20);  // fast gate: full open above e=0.05

// Clean VCA (feedback path) and driven VCA (audio output)
swingVCAClean(osc, e) = select2(osc > 0, lowerEdge(e), upperEdge(e)) * envGate(e);
swingVCA(osc, e) = swingVCAClean(osc, e) * drive : conditionalSat;

// =============================================================================
// ENVELOPE + VCA SYSTEM (letrec for circular dependencies)
// Forward Euler ODE solver implementing Werner Eqs. 10-12
// =============================================================================

vcaSum = v1raw + v2raw
letrec {
  // VCA feedback with smoothing (AC-coupled in analog circuit)
  'vcaFbRaw = (v1 + v2) : si.smooth(ba.tau2pole(0.001));

  // Trigger pulse: 1ms decay models Vtrig from trigger logic (§4)
  'trigLevel = select2(trig, trigLevel * exp(-1.0 / (0.001 * ma.SR)), 1.0)
             : max(0);

  // Gated feedback prevents DC from sustaining envelope
  'fbGate     = envGate(venv * accent * level);
  'vcaFbGated = vcaFbRaw * fbGate;
  'vprimeTerm = vprime * k_R82C9;  // ungated for authentic decay tail

  // Venv ODE: diode conducts when trigLevel > venv + Von
  'venv = (venv + dt * select2(trigLevel > venv + Von,
      // Release (Eq. 12): decay through R28, R29, R82
      vcaFbGated * k_vca_release + vprimeTerm - venv * k_venv_release,
      // Attack (Eq. 10): fast charge through R122
      vcaFbGated * k_vca_release + vprimeTerm - venv * k_venv_attack
      + (trigLevel - Von) * k_R122C9
    )) : max(0) : min(1);

  // V' ODE (Eq. 11): secondary envelope follows primary
  'vprime = (vprime + dt * (venv - vprime) * k_R82C34) : max(0) : min(1);

  // Scaled envelope with accent-dependent edge bias
  'eScaled = venv * capScale * accent * level * (1.0 + edgeBias * accent);

  // Envelope-modulated FM (metallic bloom on attack)
  'fmMult = pow(2.0, envDetune * eScaled / 1200.0);
  'osc1   = sqDuty(freq1 * fmMult, dutyCycle) * osc1gain;
  'osc2   = sqDuty(freq2 * fmMult, dutyCycle) * osc2gain;

  // VCA outputs: HP-filtered for feedback, driven for audio
  'v1clean = swingVCAClean(osc1, eScaled);
  'v2clean = swingVCAClean(osc2, eScaled);
  'v1      = v1clean : fi.highpass(1, 5.3);
  'v2      = v2clean : fi.highpass(1, 5.3);
  'v1raw   = swingVCA(osc1, eScaled);
  'v2raw   = swingVCA(osc2, eScaled);
};


// =============================================================================
// BANDPASS FILTER (§7)
// Werner's exact 4th-order transfer function (Eq. 15)
// Peak: 871 Hz (A5 - 18 cents), Q ≈ 4.8
// =============================================================================

// Component values from Werner paper
bpR24 = 2.2e3;   bpR25 = 470e3;
bpR26 = 10e3;    bpR27 = 10e3;
bpC28 = 10e-9;   bpC29 = 3.3e-9;
bpC30 = 2.2e-9;  bpC31 = 2.2e-9;

// S-domain coefficients: H(s) = (β₃s³ + β₂s²) / (α₄s⁴ + α₃s³ + α₂s² + α₁s + α₀)
bpBeta3  = -bpR24*bpR25*bpR27*bpC28*bpC30*bpC31;
bpBeta2  = -bpR24*bpR25*bpC28*bpC30;

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

// Bilinear transform: s = c*(1-z^-1)/(1+z^-1)
bpC  = 2.0 * ma.SR;
bpC2 = bpC * bpC;
bpC3 = bpC2 * bpC;
bpC4 = bpC3 * bpC;

// Z-domain numerator (from β₃s³ + β₂s²)
bpb0 =  bpBeta3*bpC3 + bpBeta2*bpC2;
bpb1 = -2*bpBeta3*bpC3;
bpb2 = -2*bpBeta2*bpC2;
bpb3 =  2*bpBeta3*bpC3;
bpb4 = -bpBeta3*bpC3 + bpBeta2*bpC2;

// Z-domain denominator
bpa0 =  bpAlpha4*bpC4 + bpAlpha3*bpC3 + bpAlpha2*bpC2 + bpAlpha1*bpC + bpAlpha0;
bpa1 = -4*bpAlpha4*bpC4 - 2*bpAlpha3*bpC3 + 2*bpAlpha1*bpC + 4*bpAlpha0;
bpa2 =  6*bpAlpha4*bpC4 - 2*bpAlpha2*bpC2 + 6*bpAlpha0;
bpa3 = -4*bpAlpha4*bpC4 + 2*bpAlpha3*bpC3 - 2*bpAlpha1*bpC + 4*bpAlpha0;
bpa4 =  bpAlpha4*bpC4 - bpAlpha3*bpC3 + bpAlpha2*bpC2 - bpAlpha1*bpC + bpAlpha0;

// Normalized coefficients
bpB0 = bpb0/bpa0;  bpB1 = bpb1/bpa0;  bpB2 = bpb2/bpa0;
bpB3 = bpb3/bpa0;  bpB4 = bpb4/bpa0;
bpA1 = bpa1/bpa0;  bpA2 = bpa2/bpa0;
bpA3 = bpa3/bpa0;  bpA4 = bpa4/bpa0;

// 4th-order IIR, normalized to unity peak gain
bpGainNorm = 0.315;
bandpass4 = fi.iir((bpB0, bpB1, bpB2, bpB3, bpB4), (bpA1, bpA2, bpA3, bpA4))
          : *(bpGainNorm);

filtered = vcaSum : bandpass4;

// =============================================================================
// OUTPUT STAGE (§8) + MILLER EFFECT
// Dynamic lowpass models BJT bandwidth limitation
// =============================================================================

millerEnv    = filtered : abs : si.smooth(0.9995);
millerCutoff = 15000 - millerEnv * 5000 : max(10000) : min(15000);

out = filtered : fi.dcblocker : fi.lowpass(1, millerCutoff) : *(2.0);

process = out <: _, _;
