import { useRef } from 'react'
import { useBreathCycle } from '../../EbbAndFlow/useBreathCycle'
import {
  estimateBreathPeriodMs, meanOf,
  buildReviewEntry, pearsonRArrays,
  computeMLRPredictions, getPacerRadius, getPacerRadiusForTrial,
} from '../breathUtils'
import { BASE_BREATH_SPEED_S, BASELINE_BREATHS_COUNT, CONDITION_BREATHS_COUNT } from '../constants'

const BASE_MS   = BASE_BREATH_SPEED_S * 1000
const SAMPLE_MS = 40  // ~25 Hz breathValue sampling

// ── COM trigger vocabulary (trial-level) ──────────────────────────────────
// 10  trial start       — baseline breaths begin
// 11  condition onset   — breath 3 begins  (DISABLED: glitches the animation;
//                         recover condition onset offline from logs + 10/12)
// 12  trial end
// Phase-level codes (1–9) fired from BreathBelt.jsx.

// ── useTrialRunner ────────────────────────────────────────────────────────
//
// Props:
//   breathValueRef          — live 0–1 signal ref
//   sendTrigger             — COM trigger fn
//   currentPhaseRef         — for raw row labelling
//   currentTrialRef
//   getAndClearTrialSamples — retrieves raw {t,x,y,z} from useBeltConnection
//   mlrWeightsRef           — current fitted model (null before calibration)
//
// Returns from runTrial:
//   beltSyncMean            — mean breathValue during condition window
//   btBaselinePeriodMs      — period estimate, baseline breaths (null if < 2 peaks)
//   btConditionPeriodMs     — period estimate, condition breaths
//   syncMetrics             — offline quality metrics (null if insufficient samples)
//
// syncMetrics shape:
//   { trialRBaseline, trialRCondition, peakErrorMs, pacerPts, beltPts }
//   pacerPts/beltPts are included for Phase 2 SignalGraph; present even for
//   Phase 3 (TrialSyncOverlay simply doesn't render the graph there).

export function useTrialRunner({
  breathValueRef,
  sendTrigger,
  currentPhaseRef,
  currentTrialRef,
  getAndClearTrialSamples,
  mlrWeightsRef,
}) {
  const { getPhase, startBreath, reset } = useBreathCycle()
  const controlRef = useRef(null)

  const baselineSamplesRef  = useRef([])
  const conditionSamplesRef = useRef([])
  const intervalRef         = useRef(null)

  function startSampling(target) {
    if (intervalRef.current) clearInterval(intervalRef.current)
    if (target === 'baseline') baselineSamplesRef.current  = []
    else                       conditionSamplesRef.current = []
    intervalRef.current = setInterval(() => {
      const v = breathValueRef.current ?? 0
      if (target === 'baseline') baselineSamplesRef.current.push(v)
      else                       conditionSamplesRef.current.push(v)
    }, SAMPLE_MS)
  }

  function stopSampling() {
    if (intervalRef.current) { clearInterval(intervalRef.current); intervalRef.current = null }
  }

  async function runTrial(phaseLabel, trialIdx, conditionMs) {
    currentPhaseRef.current = phaseLabel
    currentTrialRef.current = trialIdx

    // ── Fixation: avatar already neutral from end of last trial ──────────
    // 500 ms hold before animation — clear signal to participant that
    // the trial has not started yet.
    await new Promise(r => setTimeout(r, 500))

    // ── Trial start ───────────────────────────────────────────────────────
    const trialStartMs = Date.now()
    await sendTrigger('10')

    reset()
    controlRef.current?.resumeAnimation?.()

    // Breaths 1–2: baseline pace
    startSampling('baseline')
    for (let i = 0; i < BASELINE_BREATHS_COUNT; i++) await startBreath(BASE_MS)
    stopSampling()

    // Breath 3 onset. NOTE: the condition-onset trigger (code 11) is
    // intentionally NOT emitted — sending it mid-animation stalls the breath
    // loop (trigger hold + HTTP round-trips on parallel-port rigs), snapping the
    // pacer at the breath 2→3 boundary. Condition onset is recoverable offline
    // from the log files plus the trial-start (10) and trial-end (12) triggers.

    // Breaths 3–4: condition pace
    startSampling('condition')
    for (let i = 0; i < CONDITION_BREATHS_COUNT; i++) await startBreath(conditionMs)
    stopSampling()

    // ── Trial end ─────────────────────────────────────────────────────────
    await sendTrigger('12')
    const trialEndMs = Date.now()

    // Freeze avatar at neutral — will be held until next trial's 500 ms fixation
    controlRef.current?.resetToNeutral?.()

    currentPhaseRef.current = 'inter_trial'
    currentTrialRef.current = -1

    // ── Live period estimates ─────────────────────────────────────────────
    // Use minPeriodMs=1500 (not the free-breathing default 2000) so that
    // fast QUEST conditions (~2000ms/breath) don't fall below the threshold.
    const btBaselinePeriodMs  = estimateBreathPeriodMs(
      baselineSamplesRef.current.map((v, i) => ({ t: i * SAMPLE_MS, value: v })),
      1500
    )
    const btConditionPeriodMs = estimateBreathPeriodMs(
      conditionSamplesRef.current.map((v, i) => ({ t: i * SAMPLE_MS, value: v })),
      1500
    )
    const beltSyncMean = meanOf(conditionSamplesRef.current)

    // ── Offline sync metrics ──────────────────────────────────────────────
    // Retrieve raw {t,x,y,z} samples collected during this trial
    const rawSamples = getAndClearTrialSamples ? getAndClearTrialSamples() : []
    const mlr        = mlrWeightsRef?.current
    let syncMetrics  = null

    if (rawSamples.length > 80 && mlr) {
      const phase2StartMs    = trialStartMs + BASELINE_BREATHS_COUNT * BASE_MS
      const baselineRaw      = rawSamples.filter(s => s.t <  phase2StartMs)
      const conditionRaw     = rawSamples.filter(s => s.t >= phase2StartMs)
      const lagMs            = mlr.lagMs ?? 0

      let trialRBaseline  = null
      let trialRCondition = null

      if (baselineRaw.length > 20) {
        const bPred  = computeMLRPredictions(baselineRaw, mlr)
        const bPacer = baselineRaw.map(s => getPacerRadius(s.t, trialStartMs, BASE_MS))
        trialRBaseline = pearsonRArrays(bPred, bPacer)
      }

      if (conditionRaw.length > 20) {
        const cPred      = computeMLRPredictions(conditionRaw, mlr)
        // Lag-correct: shift pacer reference back by belt lag
        const cPacerLag  = conditionRaw.map(s =>
          getPacerRadiusForTrial(s.t - lagMs, trialStartMs, BASE_MS, conditionMs)
        )
        trialRCondition = pearsonRArrays(cPred, cPacerLag)
      }

      // buildReviewEntry handles full trial: pacerPts, beltPts, peakErrorMs
      const review = buildReviewEntry(rawSamples, mlr, trialStartMs, BASE_MS, conditionMs, phaseLabel)

      syncMetrics = {
        trialRBaseline,
        trialRCondition,
        peakErrorMs:  review.scoreMs,
        pacerPts:     review.pacerPts,   // used by TrialSyncOverlay Phase 2 graph
        beltPts:      review.beltPts,    // present but not rendered in Phase 3
      }
    }

    return { beltSyncMean, btBaselinePeriodMs, btConditionPeriodMs, syncMetrics, trialStartMs, trialEndMs }
  }

  return { getPhase, runTrial, controlRef }
}
