import {
  QUEST_FASTER_PRIOR_MEAN, QUEST_FASTER_PRIOR_SD,
  QUEST_SLOWER_PRIOR_MEAN, QUEST_SLOWER_PRIOR_SD,
  QUEST_BETA, QUEST_LAPSE, QUEST_GUESS,
  QUEST_MIN_TRIALS_EACH, QUEST_SD_STOP, QUEST_MAX_TRIALS_EACH,
  PHASE1_TRIALS_PER_COND,
} from './constants'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type TrialCondition = 'SAME' | 'FASTER' | 'SLOWER'

export type ModelLabel = 'mlr-wide' | 'mlr-tight' | 'mlr-wide-lp' | 'mlr-tight-lp' | 'pca-wide' | 'pca-tight'

export type MLRWeights = {
  weights:    [number, number, number]   // [wx, wy, wz] in filtered-axis space
  bias:       number
  modelLabel: ModelLabel
  lagMs:      number   // estimated physical lag: belt signal lags pacer by this many ms
}

export type RawAccelRow = {
  phase:           string
  trial:           number
  packetTimestamp: number
  sampleIndex:     number
  x: number; y: number; z: number
  pacerRadius:     number   // NaN when no pacer is running
}

export type RawHRRow = {
  phase:     string
  trial:     number
  timestamp: number
  heartRate: number
}

export type CalibSample = { t: number; x: number; y: number; z: number }

export type FilterState3 = {
  dx:  BiquadState
  dy:  BiquadState
  dz:  BiquadState
  dlp: LPState        // post-smooth lowpass state (used only when modelLabel ends in -lp)
}

export type SignalPoint = { t: number; value: number }

export type QuestState = {
  grid:      number[]   // log10(delta_ratio) grid
  posterior: number[]   // normalized probability mass
  nTrials:   number
}

export type QuestTrialRecord = {
  trialIndex:       number
  direction:        TrialCondition
  deltaRatio:       number
  response:         TrialCondition
  correct:          boolean
  confidence:       number
  arousal:          number
  posteriorMeanLog: number
  posteriorSD:      number
}

export type TrialReviewEntry = {
  condition:  TrialCondition
  pacerPts:   SignalPoint[]
  beltPts:    SignalPoint[]
  scoreMs:    number
}

export type FileHandles = {
  accel:  FileSystemFileHandle
  hr:     FileSystemFileHandle
  trials: FileSystemFileHandle
  quest:  FileSystemFileHandle
}

// ---------------------------------------------------------------------------
// Hardware – COM port
// ---------------------------------------------------------------------------

export const getPortWriter = async () => {
  const port = await navigator.serial.requestPort()
  if (port.readable || port.writable) {
    try { await port.close(); await new Promise(r => setTimeout(r, 100)) } catch {}
  }
  await port.open({ baudRate: 115200 })
  const enc = new TextEncoderStream()
  const writableStreamClosed = enc.readable.pipeTo(port.writable)
  const writer = enc.writable.getWriter()
  return { port, writer, writableStreamClosed }
}

// ---------------------------------------------------------------------------
// Hardware – Bluetooth (Polar H10)
// ---------------------------------------------------------------------------

export const connectBluetooth = async (
  readAccChar:   React.RefObject<BluetoothRemoteGATTCharacteristic | null>,
  heartRateChar: React.RefObject<BluetoothRemoteGATTCharacteristic | null>,
): Promise<void> => {
  const device = await navigator.bluetooth.requestDevice({
    filters: [{ services: ['heart_rate'] }],
    optionalServices: ['fb005c80-02e7-f387-1cad-8acd2d8df0c8'],
    acceptAllDevices: false,
  })
  const server = await device.gatt?.connect()
  await new Promise(r => setTimeout(r, 1000))

  const accelSvc     = await server?.getPrimaryService('fb005c80-02e7-f387-1cad-8acd2d8df0c8')
  const hrSvc        = await server?.getPrimaryService('heart_rate')
  const activate     = await accelSvc?.getCharacteristic('fb005c81-02e7-f387-1cad-8acd2d8df0c8')
  const readAcc      = await accelSvc?.getCharacteristic('fb005c82-02e7-f387-1cad-8acd2d8df0c8')
  const readHR       = await hrSvc?.getCharacteristic('heart_rate_measurement')

  if (!readAcc) throw new Error('Accelerometer characteristic not found')
  if (!readHR)  throw new Error('Heart rate characteristic not found')

  readAccChar.current   = readAcc
  heartRateChar.current = readHR

  await new Promise(r => setTimeout(r, 1000))
  await activate?.writeValue(
    new Uint8Array([0x02,0x02,0x00,0x01,0xC8,0x00,0x01,0x01,0x10,0x00,0x02,0x01,0x08,0x00]).buffer
  )
}

// ---------------------------------------------------------------------------
// Packet parsing
// ---------------------------------------------------------------------------

export const processAccDataView = (e: Event): number[][] => {
  const target   = e.target as BluetoothRemoteGATTCharacteristic
  const dv       = target.value
  if (!dv) return []
  const frameType  = dv.getInt8(9)
  const resolution = (frameType + 1) * 8
  const step       = Math.ceil(resolution / 8)
  const out: number[][] = []
  let offset = 10
  while (offset < dv.byteLength) {
    const x = dv.getInt16(offset, true) / 100; offset += step
    const y = dv.getInt16(offset, true) / 100; offset += step
    const z = dv.getInt16(offset, true) / 100; offset += step
    out.push([x, y, z])
  }
  return out
}

// ---------------------------------------------------------------------------
// Filters
//
// Wide bandpass  [0.1–1.0 Hz] — passes harmonics (can cause secondary peaks)
// Tight bandpass [0.1–0.4 Hz] — suppresses 2nd+ harmonics (~2x at 0.5 Hz)
// Lowpass        [0.6 Hz]     — post-smoothing on MLR output
//
// All 2nd-order Butterworth SOS, designed at fs=200 Hz via scipy.signal.butter
// ---------------------------------------------------------------------------

// Wide bandpass SOS
const W_S0_B0 =  0.00019593; const W_S0_B1 =  0.00039186; const W_S0_B2 = 0.00019593
const W_S0_A1 = -1.96405851; const W_S0_A2 =  0.96487768
const W_S1_B0 =  1.0;        const W_S1_B1 = -2.0;        const W_S1_B2 = 1.0
const W_S1_A1 = -1.99576529; const W_S1_A2 =  0.99577694

// Tight bandpass SOS
const T_S0_B0 =  0.00002206; const T_S0_B1 =  0.00004412; const T_S0_B2 = 0.00002206
const T_S0_A1 = -1.98985376; const T_S0_A2 =  0.98997540
const T_S1_B0 =  1.0;        const T_S1_B1 = -2.0;        const T_S1_B2 = 1.0
const T_S1_A1 = -1.99673910; const T_S1_A2 =  0.99675182

// Lowpass SOS (single second-order section)
const LP_B0 =  0.00008766; const LP_B1 = 0.00017531; const LP_B2 = 0.00008766
const LP_A1 = -1.97334425; const LP_A2 = 0.97369487

type BiquadState = [number, number, number, number]
type LPState     = [number, number]

const biquadStepWide = (x: number, st: BiquadState): [number, BiquadState] => {
  const y0 = W_S0_B0*x + st[0]
  const d0 = W_S0_B1*x - W_S0_A1*y0 + st[1]
  const d1 = W_S0_B2*x - W_S0_A2*y0
  const y1 = W_S1_B0*y0 + st[2]
  const d2 = W_S1_B1*y0 - W_S1_A1*y1 + st[3]
  const d3 = W_S1_B2*y0 - W_S1_A2*y1
  return [y1, [d0, d1, d2, d3]]
}

const biquadStepTight = (x: number, st: BiquadState): [number, BiquadState] => {
  const y0 = T_S0_B0*x + st[0]
  const d0 = T_S0_B1*x - T_S0_A1*y0 + st[1]
  const d1 = T_S0_B2*x - T_S0_A2*y0
  const y1 = T_S1_B0*y0 + st[2]
  const d2 = T_S1_B1*y0 - T_S1_A1*y1 + st[3]
  const d3 = T_S1_B2*y0 - T_S1_A2*y1
  return [y1, [d0, d1, d2, d3]]
}

const lpStep = (x: number, st: LPState): [number, LPState] => {
  const y  = LP_B0*x + st[0]
  const d0 = LP_B1*x - LP_A1*y + st[1]
  const d1 = LP_B2*x - LP_A2*y
  return [y, [d0, d1]]
}

type FilterVariant = 'wide' | 'tight'

const filtfiltAxis = (sig: number[], variant: FilterVariant): number[] => {
  const step = variant === 'tight' ? biquadStepTight : biquadStepWide
  let st: BiquadState = [0,0,0,0]
  const fwd = sig.map(x => { const [y,s] = step(x, st); st = s; return y })
  st = [0,0,0,0]
  return [...fwd].reverse()
    .map(x => { const [y,s] = step(x, st); st = s; return y })
    .reverse()
}

const filtfiltLP = (sig: number[]): number[] => {
  let st: LPState = [0,0]
  const fwd = sig.map(x => { const [y,s] = lpStep(x, st); st = s; return y })
  st = [0,0]
  return [...fwd].reverse()
    .map(x => { const [y,s] = lpStep(x, st); st = s; return y })
    .reverse()
}

// Keep short aliases used internally
const filtfilt      = (sig: number[]) => filtfiltAxis(sig, 'wide')
const filtfiltTight = (sig: number[]) => filtfiltAxis(sig, 'tight')

// ---------------------------------------------------------------------------
// Pacer radius  (normalized 0 = fully exhaled, 1 = fully inhaled)
// Formula matches BlueCircle keyframes: scale(0.5)→scale(1.3) half-way through
// ---------------------------------------------------------------------------

export const getPacerRadius = (t: number, startMs: number, periodMs: number): number =>
  (1 - Math.cos(2 * Math.PI * (t - startMs) / periodMs)) / 2

// Two-phase trial: breaths 1–2 at basePeriod, breaths 3–4 at changedPeriod
export const getPacerRadiusForTrial = (
  t:             number,
  trialStart:    number,
  basePeriodMs:  number,
  changedPeriodMs: number,
): number => {
  const phase2Start = trialStart + 2 * basePeriodMs
  return t <= phase2Start
    ? getPacerRadius(t, trialStart,    basePeriodMs)
    : getPacerRadius(t, phase2Start,   changedPeriodMs)
}

// ---------------------------------------------------------------------------
// 4×4 Gaussian elimination with partial pivoting
// ---------------------------------------------------------------------------

const solve4x4 = (A: number[][], b: number[]): number[] | null => {
  const n = 4
  const M = A.map((row, i) => [...row, b[i]])
  for (let col = 0; col < n; col++) {
    let pivot = col
    for (let r = col + 1; r < n; r++)
      if (Math.abs(M[r][col]) > Math.abs(M[pivot][col])) pivot = r;
    [M[col], M[pivot]] = [M[pivot], M[col]]
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

// ---------------------------------------------------------------------------
// Offline helpers — axis filtering + MLR solve
// ---------------------------------------------------------------------------

// Filter all three axes with the specified bandpass variant
const filterAxes = (samples: CalibSample[], variant: FilterVariant) => ({
  xf: filtfiltAxis(samples.map(s => s.x), variant),
  yf: filtfiltAxis(samples.map(s => s.y), variant),
  zf: filtfiltAxis(samples.map(s => s.z), variant),
})

// Solve least-squares: bias + w0*col0 + w1*col1 + w2*col2 = tgt
const solveLS3 = (col0: number[], col1: number[], col2: number[], tgt: number[]): [number,number,number,number] | null => {
  const N = col0.length
  const cols = [Array(N).fill(1) as number[], col0, col1, col2]
  const ATA: number[][] = Array.from({length:4}, () => Array(4).fill(0))
  const ATy: number[]   = Array(4).fill(0)
  for (let i=0; i<4; i++) {
    for (let j=0; j<=i; j++) {
      let s=0; for (let n=0; n<N; n++) s+=cols[i][n]*cols[j][n]
      ATA[i][j] = ATA[j][i] = s
    }
    let s=0; for (let n=0; n<N; n++) s+=cols[i][n]*tgt[n]
    ATy[i] = s
  }
  const w = solve4x4(ATA, ATy)
  return w ? [w[0],w[1],w[2],w[3]] : null
}

// Pearson r between two equal-length arrays
const pearsonR = (a: number[], b: number[]): number => {
  const N = a.length
  const am = a.reduce((s,v)=>s+v,0)/N, bm = b.reduce((s,v)=>s+v,0)/N
  let num=0, da=0, db=0
  for (let i=0; i<N; i++) {
    const ai=a[i]-am, bi=b[i]-bm
    num+=ai*bi; da+=ai*ai; db+=bi*bi
  }
  return da*db>0 ? Math.abs(num/Math.sqrt(da*db)) : 0
}
export const pearsonRArrays = pearsonR

// Cross-correlate pred vs ref to find lag (ms) that maximises Pearson r.
// Searches ±maxLagMs in steps of stepMs; returns lag in ms (positive = belt lags pacer).
const estimateLagMs = (
  pred:       number[],
  ref:        number[],
  sampleDtMs: number,
  maxLagMs:   number = 1500,
): number => {
  const maxShift = Math.round(maxLagMs / sampleDtMs)
  let bestR = -1, bestShift = 0
  for (let shift = 0; shift <= maxShift; shift++) {
    const N = pred.length - shift
    if (N < 20) continue
    const pSlice = pred.slice(shift, shift + N)
    const rSlice = ref.slice(0, N)
    const r = pearsonR(pSlice, rSlice)
    if (r > bestR) { bestR = r; bestShift = shift }
  }
  return bestShift * sampleDtMs
}

// Top-1 PCA eigenvector via power iteration (3×3)
const pca1 = (xf: number[], yf: number[], zf: number[]): [number,number,number] => {
  const N = xf.length
  // covariance matrix
  const mx=xf.reduce((s,v)=>s+v,0)/N, my=yf.reduce((s,v)=>s+v,0)/N, mz=zf.reduce((s,v)=>s+v,0)/N
  let cxx=0,cxy=0,cxz=0,cyy=0,cyz=0,czz=0
  for (let i=0; i<N; i++) {
    const dx=xf[i]-mx, dy=yf[i]-my, dz=zf[i]-mz
    cxx+=dx*dx; cxy+=dx*dy; cxz+=dx*dz; cyy+=dy*dy; cyz+=dy*dz; czz+=dz*dz
  }
  // Power iteration
  let vx=1, vy=0, vz=0
  for (let iter=0; iter<40; iter++) {
    const nx = cxx*vx + cxy*vy + cxz*vz
    const ny = cxy*vx + cyy*vy + cyz*vz
    const nz = cxz*vx + cyz*vy + czz*vz
    const norm = Math.sqrt(nx*nx+ny*ny+nz*nz)
    if (norm < 1e-12) break
    vx=nx/norm; vy=ny/norm; vz=nz/norm
  }
  return [vx, vy, vz]
}

// Project samples onto eigenvector → scalar PC1 series
const projectPC1 = (xf: number[], yf: number[], zf: number[], ev: [number,number,number]): number[] =>
  xf.map((_,i) => ev[0]*xf[i] + ev[1]*yf[i] + ev[2]*zf[i])

// ---------------------------------------------------------------------------
// Model fitting — try 6 variants, return best by R²
// ---------------------------------------------------------------------------
//
//  mlr-wide    : MLR on wide-bandpass axes             (original approach)
//  mlr-tight   : MLR on tight-bandpass axes            (suppresses harmonics)
//  mlr-wide-lp : mlr-wide + lowpass smooth on output
//  mlr-tight-lp: mlr-tight + lowpass smooth on output
//  pca-wide    : project onto PC1 of wide-filtered axes, then regress
//  pca-tight   : project onto PC1 of tight-filtered axes, then regress

export type ModelFitResult = { mlr: MLRWeights; r: number; modelLabel: ModelLabel; lagMs: number }

export const fitBestModel = (
  samples:        CalibSample[],
  calibStartMs:   number,
  breathPeriodMs: number,
): ModelFitResult | null => {
  if (samples.length < 100) return null

  const tgt = samples.map(s => getPacerRadius(s.t, calibStartMs, breathPeriodMs))
  const variants: FilterVariant[] = ['wide', 'tight']
  let best: ModelFitResult | null = null

  for (const v of variants) {
    const {xf, yf, zf} = filterAxes(samples, v)

    // --- MLR ---
    const wm = solveLS3(xf, yf, zf, tgt)
    if (wm) {
      const pred = samples.map((_,i) => wm[0] + wm[1]*xf[i] + wm[2]*yf[i] + wm[3]*zf[i])
      const r = pearsonR(pred, tgt)
      const label: ModelLabel = `mlr-${v}` as ModelLabel
      if (!best || r > best.r) best = { mlr: { bias:wm[0], weights:[wm[1],wm[2],wm[3]], modelLabel:label }, r }

      // --- MLR + lowpass smooth ---
      const predLP = filtfiltLP(pred)
      const rLP = pearsonR(predLP, tgt)
      const labelLP: ModelLabel = `mlr-${v}-lp` as ModelLabel
      if (rLP > best.r) best = { mlr: { bias:wm[0], weights:[wm[1],wm[2],wm[3]], modelLabel:labelLP }, r:rLP }
    }

    // --- PCA top-1 → regress ---
    const ev = pca1(xf, yf, zf)
    const pc1 = projectPC1(xf, yf, zf, ev)
    const wp = solveLS3(pc1, pc1, pc1, tgt)  // scalar regression via 1 predictor
    if (wp) {
      // scalar: r^ = bias + w*pc1 — encode as weights = w*ev
      const w1 = wp[1]  // only first coefficient used; other two are degenerate (collinear)
      const predPC = pc1.map(v => wp[0] + w1*v)
      const rPC = pearsonR(predPC, tgt)
      // Re-express in original-axis space: weights = w1 * eigenvector
      const labelPC: ModelLabel = `pca-${v}` as ModelLabel
      if (rPC > best.r) best = {
        mlr: { bias:wp[0], weights:[w1*ev[0], w1*ev[1], w1*ev[2]], modelLabel:labelPC }, r:rPC
      }
    }
  }

  // Estimate lag for the winning model
  if (best) {
    const variant: FilterVariant = best.mlr.modelLabel.includes('tight') ? 'tight' : 'wide'
    const {xf, yf, zf} = filterAxes(samples, variant)
    const raw = samples.map((_,i) =>
      best!.mlr.bias + best!.mlr.weights[0]*xf[i] + best!.mlr.weights[1]*yf[i] + best!.mlr.weights[2]*zf[i]
    )
    const pred = best.mlr.modelLabel.endsWith('-lp') ? filtfiltLP(raw) : raw
    const sampleDtMs = (samples[samples.length-1].t - samples[0].t) / (samples.length - 1)
    const lagMs = estimateLagMs(pred, tgt, sampleDtMs)
    best = { ...best, lagMs, mlr: { ...best.mlr, lagMs } }
  }

  return best
}

// ---------------------------------------------------------------------------
// Offline predictions — respects model filter and post-smooth
// ---------------------------------------------------------------------------

export const computeMLRPredictions = (
  samples: CalibSample[],
  mlr:     MLRWeights,
): number[] => {
  const variant: FilterVariant = mlr.modelLabel.includes('tight') ? 'tight' : 'wide'
  const {xf, yf, zf} = filterAxes(samples, variant)
  const raw = samples.map((_,i) =>
    mlr.bias + mlr.weights[0]*xf[i] + mlr.weights[1]*yf[i] + mlr.weights[2]*zf[i]
  )
  return mlr.modelLabel.endsWith('-lp') ? filtfiltLP(raw) : raw
}

// Pearson r between belt predictions and pacer — quality metric
export const computeCalibFitR = (
  samples:        CalibSample[],
  mlr:            MLRWeights,
  calibStartMs:   number,
  breathPeriodMs: number,
): number => {
  const pred = computeMLRPredictions(samples, mlr)
  const ref  = samples.map(s => getPacerRadius(s.t, calibStartMs, breathPeriodMs))
  return pearsonR(pred, ref)
}

// ---------------------------------------------------------------------------
// Live (causal) filter state + processing
// ---------------------------------------------------------------------------

export const initFilterState3 = (): FilterState3 => ({
  dx: [0,0,0,0], dy: [0,0,0,0], dz: [0,0,0,0], dlp: [0,0],
})

// Process one BT packet through causal bandpass → MLR → optional LP smoothing
export const processPacketMLR = (
  rawSamples: number[][],
  state:      FilterState3,
  mlr:        MLRWeights,
): { prediction: number; state: FilterState3 } => {
  const tight  = mlr.modelLabel.includes('tight')
  const step   = tight ? biquadStepTight : biquadStepWide
  let dx = state.dx, dy = state.dy, dz = state.dz, dlp = state.dlp
  let lx = 0, ly = 0, lz = 0
  for (const s of rawSamples) {
    const [fx, ndx] = step(s[0], dx); dx=ndx; lx=fx
    const [fy, ndy] = step(s[1], dy); dy=ndy; ly=fy
    const [fz, ndz] = step(s[2], dz); dz=ndz; lz=fz
  }
  let prediction = mlr.bias + mlr.weights[0]*lx + mlr.weights[1]*ly + mlr.weights[2]*lz
  if (mlr.modelLabel.endsWith('-lp')) {
    const [smoothed, nlp] = lpStep(prediction, dlp)
    prediction = smoothed; dlp = nlp
  }
  return { prediction, state: {dx, dy, dz, dlp} }
}

// Rolling Pearson r between recent belt predictions and current pacer.
// lagMs shifts the pacer reference forward so it aligns with the (lagged) belt signal.
export const rollingPearsonR = (
  predictions:    SignalPoint[],
  pacerStartMs:   number,
  pacerPeriodMs:  number,
  lagMs:          number = 0,
): number => {
  const N = predictions.length
  if (N < 10) return 0
  // Shift pacer reference back by lagMs so it aligns with the belt
  const ref = predictions.map(p => getPacerRadius(p.t - lagMs, pacerStartMs, pacerPeriodMs))
  const sig = predictions.map(p => p.value)
  const rm  = ref.reduce((a,b)=>a+b,0)/N
  const sm  = sig.reduce((a,b)=>a+b,0)/N
  let num=0, dr=0, ds=0
  for (let i=0; i<N; i++) {
    const r=ref[i]-rm, s=sig[i]-sm
    num+=r*s; dr+=r*r; ds+=s*s
  }
  return dr*ds>0 ? Math.abs(num/Math.sqrt(dr*ds)) : 0
}

// ---------------------------------------------------------------------------
// Peak detection + timing error metric
// ---------------------------------------------------------------------------

const findLocalMaxima = (
  pts: SignalPoint[],
  minSepMs: number,
): SignalPoint[] => {
  const peaks: SignalPoint[] = []
  for (let i=1; i<pts.length-1; i++) {
    if (pts[i].value > pts[i-1].value && pts[i].value > pts[i+1].value) {
      if (!peaks.length || pts[i].t - peaks[peaks.length-1].t > minSepMs) {
        peaks.push(pts[i])
      }
    }
  }
  return peaks
}

// Median |belt_peak_t – nearest_pacer_peak_t| in milliseconds
export const medianPeakTimingError = (
  beltPts:   SignalPoint[],
  pacerPts:  SignalPoint[],
  minSepMs:  number = 1500,
  lagMs:     number = 0,
): number => {
  // Shift belt peaks earlier by lagMs so they are compared in pacer-time
  const rawBeltPeaks = findLocalMaxima(beltPts, minSepMs * 0.5)
  const beltPeaks    = rawBeltPeaks.map(p => ({ ...p, t: p.t - lagMs }))
  const pacerPeaks   = findLocalMaxima(pacerPts, minSepMs * 0.7)
  if (!beltPeaks.length || !pacerPeaks.length) return Infinity

  const errors: number[] = []
  for (const pp of pacerPeaks) {
    const nearest = beltPeaks.reduce((best, bp) =>
      Math.abs(bp.t - pp.t) < Math.abs(best.t - pp.t) ? bp : best
    )
    const err = Math.abs(nearest.t - pp.t)
    if (err < minSepMs * 0.75) errors.push(err)
  }
  if (!errors.length) return Infinity
  errors.sort((a,b) => a-b)
  return errors[Math.floor(errors.length/2)]
}

// ---------------------------------------------------------------------------
// Natural breathing — estimate period from MLR prediction peaks
// ---------------------------------------------------------------------------

export const estimateBreathPeriodMs = (
  signal:     SignalPoint[],
  minPeriodMs = 2000,
  maxPeriodMs = 8000,
): number | null => {
  if (signal.length < 10) return null

  const vals = signal.map(s => s.value)
  const min  = Math.min(...vals), max = Math.max(...vals)
  if (max - min < 1e-6) return null

  const norm = signal.map(s => ({t: s.t, value: (s.value - min)/(max - min)}))
  const peaks: number[] = []

  for (let i=2; i<norm.length-2; i++) {
    const {t, value} = norm[i]
    // Use a wider neighbourhood and lower threshold — causal filter signal is noisier
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
  for (let i=1; i<peaks.length; i++) {
    const d = peaks[i] - peaks[i-1]
    if (d >= minPeriodMs && d <= maxPeriodMs) intervals.push(d)
  }
  if (!intervals.length) return null
  intervals.sort((a,b) => a-b)
  return intervals[Math.floor(intervals.length/2)]
}

// ---------------------------------------------------------------------------
// QUEST staircase
// ---------------------------------------------------------------------------

const GRID_N   = 120
const LOG_MIN  = -2.2
const LOG_MAX  =  0.3

export const initQuest = (priorMeanLog: number, priorSDLog: number): QuestState => {
  const grid = Array.from({length: GRID_N}, (_,i) => LOG_MIN + i*(LOG_MAX-LOG_MIN)/(GRID_N-1))
  const prior = grid.map(g => Math.exp(-0.5 * Math.pow((g-priorMeanLog)/priorSDLog, 2)))
  const sum   = prior.reduce((a,b)=>a+b,0)
  return { grid, posterior: prior.map(p=>p/sum), nTrials: 0 }
}

export const initQuestFaster = () => initQuest(QUEST_FASTER_PRIOR_MEAN, QUEST_FASTER_PRIOR_SD)
export const initQuestSlower = () => initQuest(QUEST_SLOWER_PRIOR_MEAN, QUEST_SLOWER_PRIOR_SD)

export const questPosteriorMeanLog = (q: QuestState): number =>
  q.grid.reduce((s,g,i) => s + g*q.posterior[i], 0)

export const questNextDelta = (q: QuestState): number =>
  Math.pow(10, questPosteriorMeanLog(q))

export const questPosteriorSD = (q: QuestState): number => {
  const mean = questPosteriorMeanLog(q)
  const v    = q.grid.reduce((s,g,i) => s + q.posterior[i]*Math.pow(g-mean, 2), 0)
  return Math.sqrt(v)
}

export const questUpdate = (q: QuestState, deltaRatio: number, correct: boolean): QuestState => {
  const newPost = q.posterior.map((p, i) => {
    const alpha  = Math.pow(10, q.grid[i])
    const pC     = QUEST_GUESS + (1-QUEST_GUESS-QUEST_LAPSE) * (1 - Math.exp(-Math.pow(deltaRatio/alpha, QUEST_BETA)))
    return p * (correct ? pC : 1-pC)
  })
  const sum = newPost.reduce((a,b)=>a+b,0)
  return { grid: q.grid, posterior: newPost.map(p=>p/sum), nTrials: q.nTrials+1 }
}

export const shouldStopQuest = (faster: QuestState, slower: QuestState): boolean => {
  if (faster.nTrials < QUEST_MIN_TRIALS_EACH || slower.nTrials < QUEST_MIN_TRIALS_EACH) return false
  return questPosteriorSD(faster) < QUEST_SD_STOP && questPosteriorSD(slower) < QUEST_SD_STOP
}

export const questExceededMaxTrials = (faster: QuestState, slower: QuestState): boolean =>
  faster.nTrials >= QUEST_MAX_TRIALS_EACH && slower.nTrials >= QUEST_MAX_TRIALS_EACH

// ---------------------------------------------------------------------------
// Trial list builders
// ---------------------------------------------------------------------------

export const shuffleArray = <T>(arr: T[]): T[] => {
  const a = [...arr]
  for (let i=a.length-1; i>0; i--) {
    const j = Math.floor(Math.random()*(i+1));
    [a[i],a[j]] = [a[j],a[i]]
  }
  return a
}

export const buildPhase1TrialList = (): TrialCondition[] =>
  shuffleArray<TrialCondition>([
    ...Array(PHASE1_TRIALS_PER_COND).fill('SAME'),
    ...Array(PHASE1_TRIALS_PER_COND).fill('FASTER'),
    ...Array(PHASE1_TRIALS_PER_COND).fill('SLOWER'),
  ])

// QUEST block: 2 FASTER + 2 SLOWER + 1 SAME, shuffled
export const buildQuestBlock = (): TrialCondition[] =>
  shuffleArray<TrialCondition>(['FASTER','FASTER','SLOWER','SLOWER','SAME'])

// ---------------------------------------------------------------------------
// Review data construction (offline, used before showing review screens)
// ---------------------------------------------------------------------------

export const extractCalibSamples = (rows: RawAccelRow[]): CalibSample[] =>
  rows.map(r => ({
    t: r.packetTimestamp + r.sampleIndex * 5,
    x: r.x, y: r.y, z: r.z,
  }))

// Down-sample to ~40 Hz for graph display
const DS = 5

export const buildReviewEntry = (
  samples:       CalibSample[],
  mlr:           MLRWeights,
  trialStart:    number,
  basePeriodMs:  number,
  changedPeriodMs: number,
  condition:     TrialCondition,
): TrialReviewEntry => {
  if (samples.length < 20) return { condition, pacerPts:[], beltPts:[], scoreMs: Infinity }

  const belt   = computeMLRPredictions(samples, mlr)
  const pacerPts = samples
    .filter((_,i) => i%DS===0)
    .map(s => ({t: s.t, value: getPacerRadiusForTrial(s.t, trialStart, basePeriodMs, changedPeriodMs)}))
  const beltPtsAll: SignalPoint[] = samples.map((s,i) => ({t: s.t, value: belt[i]}))
  const beltPts    = beltPtsAll.filter((_,i) => i%DS===0)

  const scoreMs = medianPeakTimingError(beltPtsAll, pacerPts.map(p => p), basePeriodMs)
  return { condition, pacerPts, beltPts, scoreMs }
}

// ---------------------------------------------------------------------------
// File system API  (File System Access API — browser native)
// ---------------------------------------------------------------------------

export const initFileStorage = async (participantId: string): Promise<FileHandles> => {
  const dir  = await window.showDirectoryPicker({ mode: 'readwrite' })
  const ts   = new Date().toISOString().slice(0,19).replace(/[:.]/g,'-')
  const pfx  = `${participantId}_${ts}`

  const accel  = await dir.getFileHandle(`${pfx}_accel.csv`,  { create: true })
  const hr     = await dir.getFileHandle(`${pfx}_hr.csv`,     { create: true })
  const trials = await dir.getFileHandle(`${pfx}_trials.csv`, { create: true })
  const quest  = await dir.getFileHandle(`${pfx}_quest.csv`,  { create: true })

  await _appendRaw(accel,  'phase,trial,packet_ts,sample_idx,x,y,z,pacer_radius\n')
  await _appendRaw(hr,     'phase,trial,timestamp,heart_rate\n')
  await _appendRaw(trials, 'phase,trial,condition,base_period_s,change_period_s,start_ms,end_ms,peak_error_ms\n')
  await _appendRaw(quest,  'trial,direction,delta_ratio,response,correct,confidence,arousal,posterior_mean_log,posterior_sd\n')

  return { accel, hr, trials, quest }
}

const _appendRaw = async (handle: FileSystemFileHandle, text: string) => {
  try {
    const file     = await handle.getFile()
    const writable = await handle.createWritable({ keepExistingData: true })
    await writable.seek(file.size)
    await writable.write(text)
    await writable.close()
  } catch (e) {
    console.error('File write error:', e)
  }
}

export const flushAccelRows = async (handle: FileSystemFileHandle, rows: RawAccelRow[]) => {
  if (!rows.length) return
  const lines = rows.map(r =>
    `${r.phase},${r.trial},${r.packetTimestamp},${r.sampleIndex},${r.x},${r.y},${r.z},${isNaN(r.pacerRadius)?'':r.pacerRadius.toFixed(4)}`
  ).join('\n') + '\n'
  await _appendRaw(handle, lines)
}

export const flushHRRows = async (handle: FileSystemFileHandle, rows: RawHRRow[]) => {
  if (!rows.length) return
  const lines = rows.map(r =>
    `${r.phase},${r.trial},${r.timestamp},${r.heartRate}`
  ).join('\n') + '\n'
  await _appendRaw(handle, lines)
}

export const appendTrialRow = async (
  handle:        FileSystemFileHandle,
  phase:         string,
  trial:         number,
  condition:     TrialCondition,
  basePeriodS:   number,
  changePeriodS: number,
  startMs:       number,
  endMs:         number,
  peakErrorMs:   number,
) => {
  const line = `${phase},${trial},${condition},${basePeriodS.toFixed(3)},${changePeriodS.toFixed(3)},${startMs},${endMs},${isFinite(peakErrorMs)?peakErrorMs.toFixed(1):''}\n`
  await _appendRaw(handle, line)
}

export const appendQuestRow = async (
  handle: FileSystemFileHandle,
  rec:    QuestTrialRecord,
) => {
  const line = `${rec.trialIndex},${rec.direction},${rec.deltaRatio.toFixed(5)},${rec.response},${rec.correct?1:0},${rec.confidence},${rec.arousal},${rec.posteriorMeanLog.toFixed(4)},${rec.posteriorSD.toFixed(4)}\n`
  await _appendRaw(handle, line)
}
