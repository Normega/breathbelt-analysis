// ── breathUtils.js ─────────────────────────────────────────────────────────
//
// Full Polar H10 respiratory signal processing pipeline.
// Ported from breathbelt-main/functions.ts (new version).
// No React dependencies — pure math only.
//
// NOTE: Math.pow() used throughout instead of ** due to Vite/esbuild compat.

// ── Filter coefficients ────────────────────────────────────────────────────
// All 2nd-order Butterworth SOS, designed at fs=200 Hz via scipy.signal.butter
// Implemented as direct-form II transposed cascaded biquads.

// Wide bandpass [0.1–1.0 Hz] — passes harmonics (can cause 2× peaks)
const W_S0_B0 =  0.00019593; const W_S0_B1 =  0.00039186; const W_S0_B2 = 0.00019593
const W_S0_A1 = -1.96405851; const W_S0_A2 =  0.96487768
const W_S1_B0 =  1.0;        const W_S1_B1 = -2.0;        const W_S1_B2 = 1.0
const W_S1_A1 = -1.99576529; const W_S1_A2 =  0.99577694

// Tight bandpass [0.1–0.4 Hz] — suppresses 2nd+ harmonics
const T_S0_B0 =  0.00002206; const T_S0_B1 =  0.00004412; const T_S0_B2 = 0.00002206
const T_S0_A1 = -1.98985376; const T_S0_A2 =  0.98997540
const T_S1_B0 =  1.0;        const T_S1_B1 = -2.0;        const T_S1_B2 = 1.0
const T_S1_A1 = -1.99673910; const T_S1_A2 =  0.99675182

// Lowpass [0.6 Hz] — optional post-smooth on MLR output
const LP_B0 =  0.00008766; const LP_B1 = 0.00017531; const LP_B2 = 0.00008766
const LP_A1 = -1.97334425; const LP_A2 = 0.97369487

// ── Biquad step functions (causal, direct-form II transposed) ─────────────
// state = [d0, d1, d2, d3] for cascaded 2-stage filter (wide/tight)
// state = [d0, d1]          for single-stage LP

function biquadStepWide(x, st) {
  const y0 = W_S0_B0*x + st[0]
  const d0 = W_S0_B1*x - W_S0_A1*y0 + st[1]
  const d1 = W_S0_B2*x - W_S0_A2*y0
  const y1 = W_S1_B0*y0 + st[2]
  const d2 = W_S1_B1*y0 - W_S1_A1*y1 + st[3]
  const d3 = W_S1_B2*y0 - W_S1_A2*y1
  return [y1, [d0, d1, d2, d3]]
}

function biquadStepTight(x, st) {
  const y0 = T_S0_B0*x + st[0]
  const d0 = T_S0_B1*x - T_S0_A1*y0 + st[1]
  const d1 = T_S0_B2*x - T_S0_A2*y0
  const y1 = T_S1_B0*y0 + st[2]
  const d2 = T_S1_B1*y0 - T_S1_A1*y1 + st[3]
  const d3 = T_S1_B2*y0 - T_S1_A2*y1
  return [y1, [d0, d1, d2, d3]]
}

function lpStep(x, st) {
  const y  = LP_B0*x + st[0]
  const d0 = LP_B1*x - LP_A1*y + st[1]
  const d1 = LP_B2*x - LP_A2*y
  return [y, [d0, d1]]
}

// ── Offline filtfilt (zero-phase, forward then reverse) ───────────────────
// Used only during calibration fitting and review graph generation.
// Do NOT use for live processing — use processPacketMLR() instead.
//
// Edge padding: the tight-bandpass second stage has a pole radius of
// ~0.9984 (T_S1_A2), giving a settling time constant of ~600 samples
// (~3s at the ~200Hz accel rate) and needing ~5 time constants (~3000
// samples, ~15s) to fully decay. Filtering raw (unpadded), a cold
// zero-state start distorts the first several seconds of every array —
// e.g. the BreathBelt demo re-filters the whole accumulated session for
// each trial's graph, so early trials (with little real signal ahead of
// them) sit inside that warm-up transient and their belt-signal troughs
// come out too corrupted to detect, while later trials (more real
// preceding signal) don't. Odd-reflection padding (matching scipy's
// filtfilt default) gives the filter believable "runway" before sample 0
// so it's settled by the time real data starts, without needing minutes
// of unrelated prior recording.

const FILTFILT_PAD_SAMPLES = 3000   // ~15s at ~200Hz — see settling-time note above

function oddExtend(sig, n) {
  const left = []
  for (let k = n; k >= 1; k--) left.push(2 * sig[0] - sig[k])
  const right = []
  const last = sig.length - 1
  for (let k = 1; k <= n; k++) right.push(2 * sig[last] - sig[last - k])
  return [...left, ...sig, ...right]
}

function runFiltfilt(sig, step, stateLen) {
  const n = Math.min(FILTFILT_PAD_SAMPLES, sig.length - 1)
  const padded = n > 0 ? oddExtend(sig, n) : sig
  let st = Array(stateLen).fill(0)
  const fwd = padded.map(x => { const [y, s] = step(x, st); st = s; return y })
  st = Array(stateLen).fill(0)
  const bwd = [...fwd].reverse()
    .map(x => { const [y, s] = step(x, st); st = s; return y })
    .reverse()
  return n > 0 ? bwd.slice(n, bwd.length - n) : bwd
}

function filtfiltAxis(sig, variant) {
  const step = variant === 'tight' ? biquadStepTight : biquadStepWide
  return runFiltfilt(sig, step, 4)
}

function filtfiltLP(sig) {
  return runFiltfilt(sig, lpStep, 2)
}

// ── Filter all three axes (offline) ──────────────────────────────────────

function filterAxes(samples, variant) {
  return {
    xf: filtfiltAxis(samples.map(s => s.x), variant),
    yf: filtfiltAxis(samples.map(s => s.y), variant),
    zf: filtfiltAxis(samples.map(s => s.z), variant),
  }
}

// ── Pacer reference signal ────────────────────────────────────────────────
// Cosine waveform matching BlueCircle keyframes: 0 = exhale, 1 = inhale.
// Must match AvatarBreathPacer phase convention.

export function getPacerRadius(t, startMs, periodMs) {
  return (1 - Math.cos(2 * Math.PI * (t - startMs) / periodMs)) / 2
}

// Two-phase trial: breaths 1–2 at basePeriod, breaths 3–4 at changedPeriod
export function getPacerRadiusForTrial(t, trialStart, basePeriodMs, changedPeriodMs) {
  const phase2Start = trialStart + 2 * basePeriodMs
  return t <= phase2Start
    ? getPacerRadius(t, trialStart, basePeriodMs)
    : getPacerRadius(t, phase2Start, changedPeriodMs)
}

// ── Pearson r (absolute value) ────────────────────────────────────────────

function pearsonR(a, b) {
  const N = a.length
  if (N < 4) return 0
  const am = a.reduce((s, v) => s + v, 0) / N
  const bm = b.reduce((s, v) => s + v, 0) / N
  let num = 0, da = 0, db = 0
  for (let i = 0; i < N; i++) {
    const ai = a[i] - am, bi = b[i] - bm
    num += ai * bi; da += ai * ai; db += bi * bi
  }
  return da * db > 0 ? Math.abs(num / Math.sqrt(da * db)) : 0
}

export const pearsonRArrays = pearsonR

// ── 4×4 Gaussian elimination (for OLS normal equations) ──────────────────

function solve4x4(A, b) {
  const n = 4
  const M = A.map((row, i) => [...row, b[i]])
  for (let col = 0; col < n; col++) {
    let pivot = col
    for (let r = col + 1; r < n; r++)
      if (Math.abs(M[r][col]) > Math.abs(M[pivot][col])) pivot = r
    ;[M[col], M[pivot]] = [M[pivot], M[col]]
    if (Math.abs(M[col][col]) < 1e-14) return null
    for (let r = col + 1; r < n; r++) {
      const f = M[r][col] / M[col][col]
      for (let j = col; j <= n; j++) M[r][j] -= f * M[col][j]
    }
  }
  const x = Array(n).fill(0)
  for (let i = n - 1; i >= 0; i--) {
    x[i] = M[i][n]
    for (let j = i + 1; j < n; j++) x[i] -= M[i][j] * x[j]
    x[i] /= M[i][i]
  }
  return x
}

// Solve bias + w0*col0 + w1*col1 + w2*col2 = tgt via OLS normal equations
function solveLS3(col0, col1, col2, tgt) {
  const N = col0.length
  const cols = [Array(N).fill(1), col0, col1, col2]
  const ATA = Array.from({ length: 4 }, () => Array(4).fill(0))
  const ATy = Array(4).fill(0)
  for (let i = 0; i < 4; i++) {
    for (let j = 0; j <= i; j++) {
      let s = 0; for (let n = 0; n < N; n++) s += cols[i][n] * cols[j][n]
      ATA[i][j] = ATA[j][i] = s
    }
    let s = 0; for (let n = 0; n < N; n++) s += cols[i][n] * tgt[n]
    ATy[i] = s
  }
  const w = solve4x4(ATA, ATy)
  return w ? [w[0], w[1], w[2], w[3]] : null
}

// ── PCA: top eigenvector via power iteration (3×3) ────────────────────────

function pca1(xf, yf, zf) {
  const N = xf.length
  const mx = xf.reduce((s, v) => s + v, 0) / N
  const my = yf.reduce((s, v) => s + v, 0) / N
  const mz = zf.reduce((s, v) => s + v, 0) / N
  let cxx = 0, cxy = 0, cxz = 0, cyy = 0, cyz = 0, czz = 0
  for (let i = 0; i < N; i++) {
    const dx = xf[i]-mx, dy = yf[i]-my, dz = zf[i]-mz
    cxx += dx*dx; cxy += dx*dy; cxz += dx*dz
    cyy += dy*dy; cyz += dy*dz; czz += dz*dz
  }
  let vx = 1, vy = 0, vz = 0
  for (let iter = 0; iter < 40; iter++) {
    const nx = cxx*vx + cxy*vy + cxz*vz
    const ny = cxy*vx + cyy*vy + cyz*vz
    const nz = cxz*vx + cyz*vy + czz*vz
    const norm = Math.sqrt(nx*nx + ny*ny + nz*nz)
    if (norm < 1e-12) break
    vx = nx/norm; vy = ny/norm; vz = nz/norm
  }
  return [vx, vy, vz]
}

function projectPC1(xf, yf, zf, ev) {
  return xf.map((_, i) => ev[0]*xf[i] + ev[1]*yf[i] + ev[2]*zf[i])
}

// ── Lag estimation via cross-correlation ─────────────────────────────────
// Returns lag in ms (positive = belt lags pacer). Searches up to maxLagMs.

function estimateLagMs(pred, ref, sampleDtMs, maxLagMs = 1500) {
  const maxShift = Math.round(maxLagMs / sampleDtMs)
  let bestR = -1, bestShift = 0
  for (let shift = 0; shift <= maxShift; shift++) {
    const N = pred.length - shift
    if (N < 20) continue
    const r = pearsonR(pred.slice(shift, shift + N), ref.slice(0, N))
    if (r > bestR) { bestR = r; bestShift = shift }
  }
  return bestShift * sampleDtMs
}

// ── fitBestModel ──────────────────────────────────────────────────────────
//
// Evaluates 6 model variants, returns the one with highest Pearson R.
// samples: CalibSample[] = array of { t, x, y, z } (wall-clock ms)
// Returns null if samples < 100 or all fits fail.
//
// Returned shape:
//   { bias, weights: [wx,wy,wz], modelLabel, lagMs, fitR }
//   modelLabel: 'mlr-wide' | 'mlr-tight' | 'mlr-wide-lp' | 'mlr-tight-lp' | 'pca-wide' | 'pca-tight'

export function fitBestModel(samples, calibStartMs, breathPeriodMs) {
  if (samples.length < 100) return null

  const tgt = samples.map(s => getPacerRadius(s.t, calibStartMs, breathPeriodMs))
  let best = null

  for (const v of ['wide', 'tight']) {
    const { xf, yf, zf } = filterAxes(samples, v)

    // MLR
    const wm = solveLS3(xf, yf, zf, tgt)
    if (wm) {
      const pred = samples.map((_, i) => wm[0] + wm[1]*xf[i] + wm[2]*yf[i] + wm[3]*zf[i])
      const r    = pearsonR(pred, tgt)
      if (!best || r > best.fitR) {
        best = { bias: wm[0], weights: [wm[1], wm[2], wm[3]], modelLabel: `mlr-${v}`, fitR: r }
      }

      // MLR + LP smooth
      const predLP = filtfiltLP(pred)
      const rLP    = pearsonR(predLP, tgt)
      if (rLP > best.fitR) {
        best = { bias: wm[0], weights: [wm[1], wm[2], wm[3]], modelLabel: `mlr-${v}-lp`, fitR: rLP }
      }
    }

    // PCA → scalar regression
    const ev  = pca1(xf, yf, zf)
    const pc1 = projectPC1(xf, yf, zf, ev)
    const wp  = solveLS3(pc1, pc1, pc1, tgt)
    if (wp) {
      const w1    = wp[1]
      const predPC = pc1.map(v2 => wp[0] + w1*v2)
      const rPC   = pearsonR(predPC, tgt)
      if (!best || rPC > best.fitR) {
        best = {
          bias:       wp[0],
          weights:    [w1*ev[0], w1*ev[1], w1*ev[2]],
          modelLabel: `pca-${v}`,
          fitR:       rPC,
        }
      }
    }
  }

  if (!best) return null

  // Estimate lag for winning model
  const variant = best.modelLabel.includes('tight') ? 'tight' : 'wide'
  const { xf, yf, zf } = filterAxes(samples, variant)
  const raw = samples.map((_, i) =>
    best.bias + best.weights[0]*xf[i] + best.weights[1]*yf[i] + best.weights[2]*zf[i]
  )
  const pred = best.modelLabel.endsWith('-lp') ? filtfiltLP(raw) : raw
  const sampleDtMs = samples.length > 1
    ? (samples[samples.length-1].t - samples[0].t) / (samples.length - 1)
    : 5
  const lagMs = estimateLagMs(pred, tgt, sampleDtMs)

  return { ...best, lagMs }
}

// ── computeMLRPredictions ─────────────────────────────────────────────────
// Offline predictions from CalibSample array using fitted MLR weights.
// Returns array of predicted values aligned to samples[].

export function computeMLRPredictions(samples, mlr) {
  const variant = mlr.modelLabel.includes('tight') ? 'tight' : 'wide'
  const { xf, yf, zf } = filterAxes(samples, variant)
  const raw = samples.map((_, i) =>
    mlr.bias + mlr.weights[0]*xf[i] + mlr.weights[1]*yf[i] + mlr.weights[2]*zf[i]
  )
  return mlr.modelLabel.endsWith('-lp') ? filtfiltLP(raw) : raw
}

// ── initFilterState3 ──────────────────────────────────────────────────────
// Initial causal filter state. Persists across BT packets for live processing.
// { dx, dy, dz } are 4-element biquad states; dlp is 2-element LP state.

export function initFilterState3() {
  return { dx: [0,0,0,0], dy: [0,0,0,0], dz: [0,0,0,0], dlp: [0,0] }
}

// ── processPacketMLR ─────────────────────────────────────────────────────
// Live (causal) processing of one BT packet.
// rawSamples: number[][] each [x, y, z]
// Returns { prediction, state, filtered: [fx, fy, fz] }
//   filtered = the last bandpassed per-axis values, for signal-quality /
//   explained-variance monitoring (the covariance of these three across a
//   window vs. the projection direction detects posture/fit drift).

export function processPacketMLR(rawSamples, state, mlr) {
  const tight = mlr.modelLabel.includes('tight')
  const step  = tight ? biquadStepTight : biquadStepWide
  let dx = state.dx, dy = state.dy, dz = state.dz, dlp = state.dlp
  let lx = 0, ly = 0, lz = 0
  for (const s of rawSamples) {
    const [fx, ndx] = step(s[0], dx); dx = ndx; lx = fx
    const [fy, ndy] = step(s[1], dy); dy = ndy; ly = fy
    const [fz, ndz] = step(s[2], dz); dz = ndz; lz = fz
  }
  let prediction = mlr.bias + mlr.weights[0]*lx + mlr.weights[1]*ly + mlr.weights[2]*lz
  if (mlr.modelLabel.endsWith('-lp')) {
    const [smoothed, nlp] = lpStep(prediction, dlp)
    prediction = smoothed; dlp = nlp
  }
  return { prediction, state: { dx, dy, dz, dlp }, filtered: [lx, ly, lz] }
}

// ── rollingPearsonR ───────────────────────────────────────────────────────
// Computes Pearson r between recent belt predictions and current pacer.
// lagMs shifts the pacer reference to align with the (lagged) belt signal.
// predictions: { t, value }[]

export function rollingPearsonR(predictions, pacerStartMs, pacerPeriodMs, lagMs = 0) {
  const N = predictions.length
  if (N < 10) return 0
  const ref = predictions.map(p => getPacerRadius(p.t - lagMs, pacerStartMs, pacerPeriodMs))
  const sig = predictions.map(p => p.value)
  return pearsonR(sig, ref)
}

// ── Peak detection + timing error ─────────────────────────────────────────

function findLocalMaxima(pts, minSepMs) {
  const peaks = []
  for (let i = 1; i < pts.length - 1; i++) {
    if (pts[i].value > pts[i-1].value && pts[i].value > pts[i+1].value) {
      if (!peaks.length || pts[i].t - peaks[peaks.length-1].t > minSepMs) {
        peaks.push(pts[i])
      }
    }
  }
  return peaks
}

export function medianPeakTimingError(beltPts, pacerPts, minSepMs = 1500, lagMs = 0) {
  const rawBeltPeaks = findLocalMaxima(beltPts, minSepMs * 0.5)
  const beltPeaks   = rawBeltPeaks.map(p => ({ ...p, t: p.t - lagMs }))
  const pacerPeaks  = findLocalMaxima(pacerPts, minSepMs * 0.7)
  if (!beltPeaks.length || !pacerPeaks.length) return Infinity

  const errors = []
  for (const pp of pacerPeaks) {
    const nearest = beltPeaks.reduce((best, bp) =>
      Math.abs(bp.t - pp.t) < Math.abs(best.t - pp.t) ? bp : best
    )
    const err = Math.abs(nearest.t - pp.t)
    if (err < minSepMs * 0.75) errors.push(err)
  }
  if (!errors.length) return Infinity
  errors.sort((a, b) => a - b)
  return errors[Math.floor(errors.length / 2)]
}

// ── estimateBreathPeriodMs ────────────────────────────────────────────────
// Applied to a free-breathing window. signal: { t, value }[]
// Updated to use the same peak detection logic as the new codebase.
// Returns median inter-peak interval in ms, or null if insufficient peaks.

export function estimateBreathPeriodMs(signal, minPeriodMs = 2000, maxPeriodMs = 8000) {
  if (!signal || signal.length < 10) return null

  const vals = signal.map(s => s.value)
  const min  = Math.min(...vals), max = Math.max(...vals)
  if (max - min < 1e-6) return null

  const norm  = signal.map(s => ({ t: s.t, value: (s.value - min) / (max - min) }))
  const peaks = []

  for (let i = 2; i < norm.length - 2; i++) {
    const { t, value } = norm[i]
    const isMax = value > norm[i-1].value && value > norm[i-2].value &&
                  value > norm[i+1].value && value > norm[i+2].value
    if (isMax && value > 0.40) {
      if (!peaks.length || t - peaks[peaks.length-1] > minPeriodMs * 0.6) {
        peaks.push(t)
      }
    }
  }

  if (peaks.length < 2) return null
  const intervals = []
  for (let i = 1; i < peaks.length; i++) {
    const d = peaks[i] - peaks[i-1]
    if (d >= minPeriodMs && d <= maxPeriodMs) intervals.push(d)
  }
  if (!intervals.length) return null
  intervals.sort((a, b) => a - b)
  return intervals[Math.floor(intervals.length / 2)]
}

// ── buildReviewEntry ──────────────────────────────────────────────────────
// Builds { pacerPts, beltPts, scoreMs } for SignalGraph display.
// samples: CalibSample[], downsampled to ~40 Hz for display.

const DS = 5  // display every Nth sample

export function buildReviewEntry(samples, mlr, trialStart, basePeriodMs, changedPeriodMs, condition) {
  if (samples.length < 20) {
    return { condition, pacerPts: [], beltPts: [], scoreMs: Infinity }
  }
  const belt     = computeMLRPredictions(samples, mlr)
  const pacerPts = samples
    .filter((_, i) => i % DS === 0)
    .map(s => ({ t: s.t, value: getPacerRadiusForTrial(s.t, trialStart, basePeriodMs, changedPeriodMs) }))
  const beltPtsAll = samples.map((s, i) => ({ t: s.t, value: belt[i] }))
  const beltPts    = beltPtsAll.filter((_, i) => i % DS === 0)
  // Peak detection min-separation must accommodate the *faster* of the two
  // breath periods, else faster-condition peaks get coalesced and missed.
  const minSepMs   = Math.min(basePeriodMs, changedPeriodMs)
  const scoreMs    = medianPeakTimingError(beltPtsAll, pacerPts, minSepMs)
  return { condition, pacerPts, beltPts, scoreMs }
}

// ── meanOf ────────────────────────────────────────────────────────────────

export function meanOf(arr) {
  if (!arr || arr.length === 0) return null
  return arr.reduce((a, b) => a + b, 0) / arr.length
}
