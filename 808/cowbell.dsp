import("stdfaust.lib");

////////////////////////////////////////////////////////////
// 808 COWBELL
// Based on Werner, Abel & Smith, AES 2014:
// "More Cowbell: A Physically-Informed, Circuit-Bendable,
//  Digital Model of the TR-808 Cowbell"
// Part values from the TR-808 service notes (voicing board),
// as in the paper's Fig. 1.
////////////////////////////////////////////////////////////
//
// === THE STOCK PATH: WERNER'S MODEL, IN VOLTS ===
//
// §3 Schmitt trigger oscillators: 540 / 800 Hz, 0..5 V,
//    duty 0.4798 (HD14584 thresholds), free-running,
//    alias-suppressed.
// §4 Trigger: a 1 ms pulse whose height is the accent level,
//    Vct = 7 V (velocity 0) .. 14 V (velocity 1).
// §5 Envelope generator: C9 charged through R122 and a diode,
//    dumping into C34 through R82, loaded by the two VCA
//    collectors through R28 / R29 (Eqs. 10-12, forward Euler).
//    Accent changes the decay's shape as well as its height.
// §6 Swing-type VCAs: each a rectangle between Werner's fitted
//    lower and upper edges (Table 1), set by the envelope.
// §7 Band pass: Eq. 15, bilinear transform.
// §8 Level control: the two coupling high passes and the pot.
//
// Beyond Werner, where the model needs it:
// - Below the fit's range (0.5 V) the swing fades out by
//   0.4 V; the collectors only draw on C9 (D3 / D4).
//
// === MODS (each at its stock setting by default) ===
//
// decay x, drive, osc balance, env detune, duty mod,
// edge bias, keytrack, miller lowpass, cap recovery.
//
////////////////////////////////////////////////////////////

declare options "[midi:on][nvoices:1]";

// =============================================================================
// CONTROLS
// =============================================================================

gate  = button("gate");
gain  = hslider("gain", 0.5, 0, 1, 0.01);    // MIDI velocity: the accent level
level = hslider("level", 0.8, 0, 1, 0.01);   // VR5
freq  = hslider("freq", 540, 200, 2000, 0.01);

// Mods (Werner §9 style circuit bends); each default is the stock circuit
decayX     = hslider("h:mods/decay x", 1, 0.25, 4, 0.01);       // scales R82, R28, R29
drive      = hslider("h:mods/drive", 0, 0, 10, 0.1);            // tanh on the VCAs (0 = off)
oscBalance = hslider("h:mods/osc balance", 0.5, 0, 1, 0.01);    // 0 osc 1, 1 osc 2
envDetune  = hslider("h:mods/env detune", 0, 0, 100, 0.1);      // cents at 8 V of envelope
dutyMod    = hslider("h:mods/duty mod", 0, 0, 0.05, 0.001);     // accent shifts the duty
edgeBias   = hslider("h:mods/edge bias", 0, 0, 0.5, 0.01);      // accent widens the swing
keytrack   = checkbox("h:mods/keytrack");                       // MIDI pitch retunes, 800/540 kept
miller     = checkbox("h:mods/miller lowpass");                 // a lowpass darkening loud hits
recovery   = checkbox("h:mods/cap recovery");                   // quick retriggers come out weaker

// =============================================================================
// TRIGGER (§4)
// =============================================================================

trig     = gate : ba.impulsify : *(ba.time > 100);   // rising edge, past the startup
hasFired = trig : max ~ _;
since    = (+(1) : *(1 - trig)) ~ _;                 // samples since the last trigger

// mod: capacitor recovery, the trigger's level recharging over 400 ms after each hit
// (kept as its shortfall, so it starts charged)
chargeCoef = exp(-1.0 / (0.4 * ma.SR));
shortfall  = (_ <: select2(trig, _ * chargeCoef, 1.0 - (1.0 - _) * 0.05)) ~ _;
capScale   = 1.0 - ba.sAndH(trig, shortfall') : max(0.1);

accent = gain : ba.sAndH(trig);
vct    = (7.0 + 7.0 * accent) * select2(recovery, 1.0, capScale);
vtrig  = vct * hasFired * (since < 0.001 * ma.SR);   // the 1 ms pulse

// =============================================================================
// SCHMITT TRIGGER OSCILLATORS (§3)
// =============================================================================

freq1 = select2(keytrack, 540.0, select2(hasFired, 540.0, freq : ba.sAndH(trig)));
freq2 = freq1 * (800.0 / 540.0);
duty  = 0.4798 + dutyMod * (accent - 0.5);

// 1 while high (5 V), 0 while low; alias-suppressed
schmitt(f) = os.pulsetrain(f, duty) * 0.5 + 0.5;

// =============================================================================
// ENVELOPE GENERATOR (§5) AND SWING-TYPE VCAs (§6)
// =============================================================================

C9  = 0.47e-6;  C34  = 1e-6;
R82 = 33e3 * decayX;  R28 = 100e3 * decayX;  R29 = 100e3 * decayX;  R122 = 1e3;
Von = 0.6;   // the diode (Eq. 9)
dt  = 1.0 / ma.SR;

// Werner's fitted edges (Table 1, Eqs. 13-14), over 0.5..8 V
alpha0 = 14.97;    alpha1 = -0.01872;  alpha2 = -14.33;
alpha3 = 1.011;    alpha4 = -0.03122;
beta0  = 0.01837;  beta1  = 1.813;
gamma0 = -0.3179;  gamma1 = -2.988;
fitMin = 0.5;

upperFit(v) = alpha3 * v + alpha4;
lowerFit(v) = alpha0 * exp(-beta0 * pow(v, gamma0))
            + alpha1 * exp(-beta1 * pow(v, gamma1)) + alpha2;
// below the fit the swing fades out by 0.4 V: no headroom over saturation
fade(v)  = (v - 0.4) / (2.0 * fitMin - 0.4) : max(0) : min(1);
upper(v) = upperFit(max(v, fitMin)) * fade(v);
lower(v) = lowerFit(max(v, fitMin)) * fade(v);

// the collector: a high input turns the transistor on, down to the lower edge
// (mod: edge bias raises the upper edge with accent)
vca(high, v) = lo + (1.0 - high) * (up - lo)
with {
  lo = lower(v);
  up = upper(v) + edgeBias * accent * (upper(v) - lo);
};

// mod: envelope detune, the oscillators bent up with the envelope
fm(v) = pow(2.0, envDetune * v / 8.0 / 1200.0);

vcaOuts = v1, v2
letrec {
  // Eqs. 10-12: the collectors draw on C9 through R28 / R29 and D3 / D4
  'venv = venv + dt / C9 * (
            min(v1 - venv, 0.0) / R28 + min(v2 - venv, 0.0) / R29
          + (vprime - venv) / R82
          + (vtrig >= venv + Von) * (vtrig - Von - venv) / R122) : max(0);
  'vprime = vprime + dt * (venv - vprime) / (R82 * C34);
  'v1 = vca(schmitt(freq1 * fm(venv)), venv);
  'v2 = vca(schmitt(freq2 * fm(venv)), venv);
};

// mod: drive, the VCAs' outputs saturated (in volts)
sat(v) = select2(drive > 0, v, 8.0 * ma.tanh(v * drive / 8.0));

// mod: osc balance, 0.5 both at full
osc1gain = min(1.0, 2.0 * (1.0 - oscBalance));
osc2gain = min(1.0, 2.0 * oscBalance);

vcaSum = vcaOuts : (sat * osc1gain, sat * osc2gain) :> _;

// =============================================================================
// BAND PASS (§7): Werner's Eq. 15 through the bilinear transform
// The two inputs are alike with stock parts, so one filter takes their sum.
// =============================================================================

bpR24 = 2.2e3;   bpR25 = 470e3;
bpR26 = 10e3;    bpR27 = 10e3;
bpC28 = 10e-9;   bpC29 = 3.3e-9;
bpC30 = 2.2e-9;  bpC31 = 2.2e-9;

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

bpC  = 2.0 * ma.SR;
bpC2 = bpC * bpC;
bpC3 = bpC2 * bpC;
bpC4 = bpC3 * bpC;

bpb0 =  bpBeta3*bpC3 + bpBeta2*bpC2;
bpb1 = -2*bpBeta3*bpC3;
bpb2 = -2*bpBeta2*bpC2;
bpb3 =  2*bpBeta3*bpC3;
bpb4 = -bpBeta3*bpC3 + bpBeta2*bpC2;

bpa0 =  bpAlpha4*bpC4 + bpAlpha3*bpC3 + bpAlpha2*bpC2 + bpAlpha1*bpC + bpAlpha0;
bpa1 = -4*bpAlpha4*bpC4 - 2*bpAlpha3*bpC3 + 2*bpAlpha1*bpC + 4*bpAlpha0;
bpa2 =  6*bpAlpha4*bpC4 - 2*bpAlpha2*bpC2 + 6*bpAlpha0;
bpa3 = -4*bpAlpha4*bpC4 + 2*bpAlpha3*bpC3 - 2*bpAlpha1*bpC + 4*bpAlpha0;
bpa4 =  bpAlpha4*bpC4 - bpAlpha3*bpC3 + bpAlpha2*bpC2 - bpAlpha1*bpC + bpAlpha0;

bandpass4 = fi.iir((bpb0/bpa0, bpb1/bpa0, bpb2/bpa0, bpb3/bpa0, bpb4/bpa0),
                   (bpa1/bpa0, bpa2/bpa0, bpa3/bpa0, bpa4/bpa0));

// =============================================================================
// LEVEL CONTROL (§8): C75 into R116 + VR5 (about 12 Hz), C76 into R117 (330 Hz)
// =============================================================================

filtered = vcaSum : bandpass4 : fi.highpass(1, 12) : fi.highpass(1, 330);

// mod: miller lowpass, about 15 kHz at rest, down to 10 kHz on loud hits
millerEnv    = filtered : abs : si.smooth(0.9995);
millerCutoff = 15000 - millerEnv * 800 : max(10000) : min(15000);
millerLp(x)  = select2(miller, x, x : fi.lowpass(1, millerCutoff));

outScale = 0.065;   // volts to full scale: full accent about 1 peak

process = filtered : millerLp : *(level * outScale) <: _, _;
