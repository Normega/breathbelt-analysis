import { useRef, useState, useCallback } from 'react'
import './styles/App.css'
import './styles/animation.css'
import logo from './assets/full_logo-2.png'

import {
  connectBluetooth, getPortWriter, processAccDataView,
  fitBestModel, computeMLRPredictions, computeCalibFitR, ModelLabel,
  initFilterState3, processPacketMLR,
  rollingPearsonR, medianPeakTimingError, pearsonRArrays,
  estimateBreathPeriodMs, extractCalibSamples, buildReviewEntry,
  initQuestFaster, initQuestSlower,
  questNextDelta, questUpdate, questPosteriorSD, questPosteriorMeanLog,
  shouldStopQuest, questExceededMaxTrials, buildQuestBlock,
  buildPhase1TrialList, shuffleArray,
  initFileStorage, flushAccelRows, flushHRRows, appendTrialRow, appendQuestRow,
  getPacerRadiusForTrial, getPacerRadius,
  MLRWeights, FilterState3, QuestState, QuestTrialRecord,
  TrialCondition, RawAccelRow, RawHRRow, SignalPoint, TrialReviewEntry, FileHandles,
  CalibSample,
} from '../../functions'

import {
  DEFAULT_BASE_PERIOD_S, CALIB_CYCLES, READY_DELAY_MS,
  NATURAL_BREATH_MIN_MS, NATURAL_BREATH_MAX_MS,
  PHASE1_DELTA_RATIO, SYNC_GOOD, SYNC_FAIR,
} from '../../constants'

import {
  AuthScreen, BlueCircle, LoadIcon,
  SynchronyBar, SaveQuitButton,
  CalibReviewPanel, Phase1ReviewPanel,
  QuestRating, QuestProgressBar,
  SignalGraph,
} from './components'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type BreathSpeedAndCount = { duration: number; iterations: number }

type AppState =
  | 'AUTH'
  | 'WAIT_FOR_BLUETOOTH' | 'CONNECTING_BT'
  | 'WAIT_FOR_COM'       | 'CONNECTING_COM'
  | 'SETUP_FILES'
  | 'CALIB_READY'   | 'CALIB_FIXATION' | 'CALIB_BREATHE' | 'CALIB_FITTING'
  | 'CALIB_REVIEW'
  | 'NATURAL_BREATHING' | 'NATURAL_BREATH_RESULT'
  | 'PHASE1_READY' | 'PHASE1_TRIAL_RUNNING'
  | 'PHASE1_REVIEW'
  | 'QUEST_READY' | 'QUEST_TRIAL_RUNNING' | 'QUEST_RATING'
  | 'QUEST_COMPLETE'
  | 'END' | 'ERROR'

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

function App() {

  // ── UI state ──────────────────────────────────────────────────────────────
  const [appState,         setAppState]         = useState<AppState>('AUTH')
  const [participantId,    setParticipantId]     = useState('')
  const [blueCirclePhases, setBlueCirclePhases]  = useState<BreathSpeedAndCount[]>([])
  const [blueCircleKey,    setBlueCircleKey]     = useState(0)
  const [syncQuality,      setSyncQuality]       = useState(0)
  const [calibFitR,        setCalibFitR]         = useState(0)
  const [calibPeakError,   setCalibPeakError]    = useState(Infinity)
  const [calibModelLabel,  setCalibModelLabel]   = useState<ModelLabel>('mlr-wide')
  const [calibLagMs,       setCalibLagMs]        = useState(0)
  const [naturalGraphPts,  setNaturalGraphPts]   = useState<SignalPoint[]>([])
  const [calibReviewPacer, setCalibReviewPacer]  = useState<SignalPoint[]>([])
  const [calibReviewBelt,  setCalibReviewBelt]   = useState<SignalPoint[]>([])
  const [naturalPeriodMs,  setNaturalPeriodMs]   = useState<number|null>(null)
  const [phase1Entries,    setPhase1Entries]     = useState<TrialReviewEntry[]>([])
  const [lastTrialGraph,   setLastTrialGraph]    = useState<{ pacerPts: SignalPoint[]; beltPts: SignalPoint[]; scoreMs: number; label: string } | null>(null)
  const [questFasterSD,    setQuestFasterSD]     = useState(1)
  const [questSlowerSD,    setQuestSlowerSD]     = useState(1)
  const [questFasterN,     setQuestFasterN]      = useState(0)
  const [questSlowerN,     setQuestSlowerN]      = useState(0)
  const [currentQuestTrialNum, setCurrentQuestTrialNum] = useState(0)
  const [showQuitConfirm,  setShowQuitConfirm]   = useState(false)

  // ── Hardware refs ─────────────────────────────────────────────────────────
  const readAccChar          = useRef<BluetoothRemoteGATTCharacteristic|null>(null)
  const heartRateChar        = useRef<BluetoothRemoteGATTCharacteristic|null>(null)
  const serialPortWriter     = useRef<any>(null)
  const serialPort           = useRef<any>(null)
  const writableStreamClosed = useRef<Promise<void>|null>(null)

  // ── Calibration refs ──────────────────────────────────────────────────────
  const calibStartMsRef     = useRef(0)
  const mlrWeightsRef       = useRef<MLRWeights|null>(null)
  const calibSamplesRef     = useRef<CalibSample[]>([])
  const filterState3Ref     = useRef<FilterState3>(initFilterState3())

  // ── Session timing ────────────────────────────────────────────────────────
  const basePeriodMsRef     = useRef(DEFAULT_BASE_PERIOD_S * 1000)

  // ── Natural breathing ─────────────────────────────────────────────────────
  const naturalSamplesRef   = useRef<SignalPoint[]>([])
  const beltLagMsRef        = useRef(0)   // physical lag from calibration
  const naturalTimerRef     = useRef<ReturnType<typeof setTimeout>|null>(null)

  // ── Phase 1 ───────────────────────────────────────────────────────────────
  const phase1ListRef         = useRef<TrialCondition[]>([])
  const currentP1IndexRef     = useRef(0)
  const p1StartTimesRef       = useRef<number[]>([])
  const p1EndTimesRef         = useRef<number[]>([])
  const p1PacerPeriods        = useRef<{base:number, changed:number}[]>([])
  const p1TrialTimerRef       = useRef<ReturnType<typeof setTimeout>|null>(null)

  // ── QUEST ─────────────────────────────────────────────────────────────────
  const questFasterRef        = useRef<QuestState>(initQuestFaster())
  const questSlowerRef        = useRef<QuestState>(initQuestSlower())
  const questBlockRef         = useRef<TrialCondition[]>([])
  const questCurrentCondRef   = useRef<TrialCondition>('SAME')
  const questCurrentDeltaRef  = useRef(0)
  const questTrialCountRef    = useRef(0)
  const questRecordsRef       = useRef<QuestTrialRecord[]>([])

  // ── Dev options ───────────────────────────────────────────────────────────
  const skipPhase1Ref         = useRef(false)

  // ── Pacer tracking (for per-packet pacerRadius logging) ───────────────────
  const pacerStartMsRef       = useRef(0)
  const pacerBasePeriodMsRef  = useRef(0)
  const pacerPhase2StartMsRef = useRef(0)
  const pacerChangedPeriodMsRef = useRef(0)
  const pacerIsActiveRef      = useRef(false)

  // ── Live sync ─────────────────────────────────────────────────────────────
  const livePredBufferRef     = useRef<SignalPoint[]>([])
  const packetCountRef        = useRef(0)

  // ── Data logging ─────────────────────────────────────────────────────────
  const rawAccelRowsRef       = useRef<RawAccelRow[]>([])
  const rawHRRowsRef          = useRef<RawHRRow[]>([])
  const pendingAccelRef       = useRef<RawAccelRow[]>([])   // unflushed rows
  const pendingHRRef          = useRef<RawHRRow[]>([])
  const currentPhaseRef       = useRef('init')
  const currentTrialRef       = useRef(-1)
  const fileHandlesRef        = useRef<FileHandles|null>(null)

  // ── Helpers ───────────────────────────────────────────────────────────────

  const setPacerForCalib = (startMs: number, periodMs: number) => {
    pacerStartMsRef.current       = startMs
    pacerBasePeriodMsRef.current  = periodMs
    pacerPhase2StartMsRef.current = Infinity
    pacerChangedPeriodMsRef.current = periodMs
    pacerIsActiveRef.current      = true
  }

  const setPacerForTrial = (startMs: number, basePeriodMs: number, changedPeriodMs: number) => {
    pacerStartMsRef.current         = startMs
    pacerBasePeriodMsRef.current    = basePeriodMs
    pacerPhase2StartMsRef.current   = startMs + 2 * basePeriodMs
    pacerChangedPeriodMsRef.current = changedPeriodMs
    pacerIsActiveRef.current        = true
  }

  const clearPacer = () => { pacerIsActiveRef.current = false }

  const currentPacerRadius = (t: number): number => {
    if (!pacerIsActiveRef.current) return NaN
    if (t < pacerPhase2StartMsRef.current) {
      return getPacerRadius(t, pacerStartMsRef.current, pacerBasePeriodMsRef.current)
    }
    return getPacerRadius(t, pacerPhase2StartMsRef.current, pacerChangedPeriodMsRef.current)
  }

  // Flush pending accel/HR rows to file (called after each trial)
  const flushPending = useCallback(async () => {
    if (!fileHandlesRef.current) return
    if (pendingAccelRef.current.length) {
      await flushAccelRows(fileHandlesRef.current.accel, pendingAccelRef.current)
      pendingAccelRef.current = []
    }
    if (pendingHRRef.current.length) {
      await flushHRRows(fileHandlesRef.current.hr, pendingHRRef.current)
      pendingHRRef.current = []
    }
  }, [])

  // ── Packet handlers ───────────────────────────────────────────────────────

  // During CALIB_BREATHE — collect raw samples + log
  const makeCalibCollectHandler = () => (e: Event) => {
    const timestamp = Date.now()
    const meas      = processAccDataView(e)
    if (!meas.length) return

    meas.forEach((s, idx) => {
      const sampleT = timestamp + idx * 5
      const row: RawAccelRow = {
        phase: 'calib', trial: -1,
        packetTimestamp: timestamp, sampleIndex: idx,
        x: s[0], y: s[1], z: s[2], pacerRadius: currentPacerRadius(sampleT),
      }
      rawAccelRowsRef.current.push(row)
      pendingAccelRef.current.push(row)
      calibSamplesRef.current.push({ t: sampleT, x: s[0], y: s[1], z: s[2] })
    })
  }

  // During natural breathing — just collect raw rows; offline filtfilt applied at end
  const makeNaturalBreathHandler = () => (e: Event) => {
    const timestamp = Date.now()
    const meas      = processAccDataView(e)
    if (!meas.length || !mlrWeightsRef.current) return

    meas.forEach((s, idx) => {
      const row: RawAccelRow = {
        phase: 'natural', trial: -1,
        packetTimestamp: timestamp, sampleIndex: idx,
        x: s[0], y: s[1], z: s[2], pacerRadius: NaN,
      }
      rawAccelRowsRef.current.push(row)
      pendingAccelRef.current.push(row)
    })
  }

  // During live phases (trials, QUEST) — MLR prediction + log + sync quality
  const makeLiveHandler = (phase: string, trial: number) => (e: Event) => {
    const timestamp = Date.now()
    const meas      = processAccDataView(e)
    if (!meas.length || !mlrWeightsRef.current) return

    meas.forEach((s, idx) => {
      const sampleT = timestamp + idx * 5
      const row: RawAccelRow = {
        phase, trial,
        packetTimestamp: timestamp, sampleIndex: idx,
        x: s[0], y: s[1], z: s[2], pacerRadius: currentPacerRadius(sampleT),
      }
      rawAccelRowsRef.current.push(row)
      pendingAccelRef.current.push(row)
    })

    // Causal filter kept for future use but sync quality now uses offline window
    const { state } = processPacketMLR(meas, filterState3Ref.current, mlrWeightsRef.current)
    filterState3Ref.current = state

    packetCountRef.current++
    // Every ~10 packets (~1.8 s) recompute sync using offline filtfilt on a
    // 3-cycle raw window.  This fully corrects for both physical lag and filter
    // group delay at the cost of ~2 s of latency — which is fine.
    if (packetCountRef.current % 10 === 0 && pacerIsActiveRef.current) {
      const periodMs   = basePeriodMsRef.current
      const windowMs   = 3 * periodMs + beltLagMsRef.current + 500  // extra margin
      const cutoff     = timestamp - windowMs
      const recentRows = rawAccelRowsRef.current.filter(
        r => r.phase === phase && r.trial === trial && r.packetTimestamp >= cutoff
      )
      if (recentRows.length > 40) {
        const samp  = extractCalibSamples(recentRows)
        const belt  = computeMLRPredictions(samp, mlrWeightsRef.current!)
        const beltPts  = samp.map((s, i) => ({ t: s.t, value: belt[i] }))
        const pacerPts = samp.map(s => ({ t: s.t - beltLagMsRef.current, value: getPacerRadius(s.t - beltLagMsRef.current, pacerStartMsRef.current, periodMs) }))
        const q = pearsonRArrays(beltPts.map(p => p.value), pacerPts.map(p => p.value))
        setSyncQuality(q)
      }
    }
  }

  // HR handler
  const hrHandler = (e: Event) => {
    const target = e.target as BluetoothRemoteGATTCharacteristic
    const hr = target.value?.getInt8(1) ?? -1
    const row: RawHRRow = {
      phase: currentPhaseRef.current, trial: currentTrialRef.current,
      timestamp: Date.now(), heartRate: hr,
    }
    rawHRRowsRef.current.push(row)
    pendingHRRef.current.push(row)
  }

  // ── Calibration sequence ─────────────────────────────────────────────────

  const startCalibSequence = () => {
    calibSamplesRef.current    = []
    filterState3Ref.current    = initFilterState3()
    mlrWeightsRef.current      = null
    currentPhaseRef.current    = 'calib'
    currentTrialRef.current    = -1

    setBlueCirclePhases([])
    setBlueCircleKey(k => k + 1)
    setAppState('CALIB_FIXATION')

    setTimeout(() => {
      const periodMs = basePeriodMsRef.current
      calibStartMsRef.current = Date.now()
      setPacerForCalib(calibStartMsRef.current, periodMs)

      if (readAccChar.current)
        readAccChar.current.oncharacteristicvaluechanged = makeCalibCollectHandler()

      setBlueCirclePhases([{ duration: periodMs/1000, iterations: CALIB_CYCLES }])
      setBlueCircleKey(k => k + 1)
      setAppState('CALIB_BREATHE')

      const breatheMs = CALIB_CYCLES * periodMs
      setTimeout(async () => {
        clearPacer()
        setAppState('CALIB_FITTING')

        // Fit MLR offline
        const fitResult = fitBestModel(calibSamplesRef.current, calibStartMsRef.current, periodMs)
        if (!fitResult) { alert('Calibration failed: insufficient data. Please try again.'); setAppState('CALIB_READY'); return }

        mlrWeightsRef.current = fitResult.mlr
        beltLagMsRef.current  = fitResult.lagMs
        setCalibModelLabel(fitResult.mlr.modelLabel)
        setCalibLagMs(fitResult.lagMs)

        // Build review data
        const belt   = computeMLRPredictions(calibSamplesRef.current, fitResult.mlr)
        const DS = 5
        const pacerPts: SignalPoint[] = calibSamplesRef.current
          .filter((_,i) => i%DS===0)
          .map(s => ({ t: s.t, value: getPacerRadius(s.t, calibStartMsRef.current, periodMs) }))
        const beltPts: SignalPoint[] = calibSamplesRef.current
          .filter((_,i) => i%DS===0)
          .map((_, i) => ({ t: calibSamplesRef.current[i*DS].t, value: belt[i*DS] }))

        const fitR    = computeCalibFitR(calibSamplesRef.current, fitResult.mlr, calibStartMsRef.current, periodMs)
        const allBelt = calibSamplesRef.current.map((s, i) => ({ t: s.t, value: belt[i] }))
        const peakErr = medianPeakTimingError(allBelt, pacerPts, periodMs, fitResult.lagMs)

        setCalibFitR(fitR)
        setCalibPeakError(peakErr)
        setCalibReviewPacer(pacerPts)
        setCalibReviewBelt(beltPts)

        await flushPending()
        setAppState('CALIB_REVIEW')
      }, breatheMs)
    }, READY_DELAY_MS)
  }

  // ── Natural breathing ─────────────────────────────────────────────────────

  const startNaturalBreathing = () => {
    filterState3Ref.current    = initFilterState3()
    currentPhaseRef.current    = 'natural'
    livePredBufferRef.current  = []
    packetCountRef.current     = 0

    if (readAccChar.current)
      readAccChar.current.oncharacteristicvaluechanged = makeNaturalBreathHandler()

    setAppState('NATURAL_BREATHING')

    // Auto-advance at max window; user can also advance early after min
    if (naturalTimerRef.current) clearTimeout(naturalTimerRef.current)
    naturalTimerRef.current = setTimeout(() => finishNaturalBreathing(), NATURAL_BREATH_MAX_MS)
  }

  const finishNaturalBreathing = () => {
    if (naturalTimerRef.current) clearTimeout(naturalTimerRef.current)

    // Run offline filtfilt on all collected raw rows — no causal filter transient
    const natRows = rawAccelRowsRef.current.filter(r => r.phase === 'natural')
    const samp    = extractCalibSamples(natRows)
    let signalPts: SignalPoint[] = []
    if (samp.length > 40 && mlrWeightsRef.current) {
      const belt = computeMLRPredictions(samp, mlrWeightsRef.current)
      const DS   = 4
      signalPts  = samp
        .filter((_,i) => i%DS===0)
        .map((s,i) => ({ t: s.t, value: belt[i*DS] }))
    }
    const estimated = estimateBreathPeriodMs(signalPts)
    setNaturalPeriodMs(estimated)
    setNaturalGraphPts(signalPts)
    setAppState('NATURAL_BREATH_RESULT')
  }

  // ── Phase 1 trials ────────────────────────────────────────────────────────

  const startPhase1 = () => {
    phase1ListRef.current     = buildPhase1TrialList()
    currentP1IndexRef.current = 0
    p1StartTimesRef.current   = []
    p1EndTimesRef.current     = []
    p1PacerPeriods.current    = []
    livePredBufferRef.current = []
    packetCountRef.current    = 0
    setLastTrialGraph(null)
    // Stop the natural-breath handler immediately — filter is reset fresh per-trial.
    if (readAccChar.current)
      readAccChar.current.oncharacteristicvaluechanged = () => {}
    setAppState('PHASE1_READY')
  }

  const runPhase1Trial = () => {
    const idx        = currentP1IndexRef.current
    const condition  = phase1ListRef.current[idx]
    const baseMs     = basePeriodMsRef.current
    const changedMs  = condition === 'FASTER' ? baseMs * (1 - PHASE1_DELTA_RATIO)
                     : condition === 'SLOWER' ? baseMs * (1 + PHASE1_DELTA_RATIO)
                     : baseMs

    p1PacerPeriods.current[idx] = { base: baseMs, changed: changedMs }

    const trialNum = idx + 1
    currentPhaseRef.current = 'phase1'
    currentTrialRef.current = trialNum

    // Reset filter state fresh at each trial start — prevents stale transient
    // from between-trial waits corrupting the causal filter output.
    filterState3Ref.current   = initFilterState3()
    livePredBufferRef.current = []

    if (readAccChar.current)
      readAccChar.current.oncharacteristicvaluechanged = makeLiveHandler('phase1', trialNum)

    setTimeout(async () => {
      const startMs = Date.now()
      p1StartTimesRef.current[idx] = startMs
      setPacerForTrial(startMs, baseMs, changedMs)

      setBlueCirclePhases([
        { duration: baseMs/1000,    iterations: 2 },
        { duration: changedMs/1000, iterations: 2 },
      ])
      setBlueCircleKey(k => k + 1)
      setAppState('PHASE1_TRIAL_RUNNING')

      try { await serialPortWriter.current?.write('1\n') } catch {}

      const durationMs = 2 * baseMs + 2 * changedMs
      if (p1TrialTimerRef.current) clearTimeout(p1TrialTimerRef.current)
      p1TrialTimerRef.current = setTimeout(async () => {
        try { await serialPortWriter.current?.write('0\n') } catch {}
        clearPacer()
        p1EndTimesRef.current[idx] = Date.now()

        await flushPending()

        // Log trial summary (compute peak error offline)
        if (fileHandlesRef.current) {
          const trialRows = rawAccelRowsRef.current.filter(r => r.phase==='phase1' && r.trial===trialNum)
          const samp      = extractCalibSamples(trialRows)
          if (samp.length > 20) {
            const belt  = computeMLRPredictions(samp, mlrWeightsRef.current!)
            const beltP = samp.map((s,i) => ({t:s.t, value:belt[i]}))
            const pacerP = samp.map(s => ({t:s.t, value:getPacerRadiusForTrial(s.t, startMs, baseMs, changedMs)}))
            const err   = medianPeakTimingError(beltP, pacerP, baseMs*0.6, beltLagMsRef.current)
            await appendTrialRow(fileHandlesRef.current.trials, 'phase1', trialNum, condition, baseMs/1000, changedMs/1000, startMs, p1EndTimesRef.current[idx], err)
          }
        }

        // Build mini-graph for the between-trial display
        const trialRowsG = rawAccelRowsRef.current.filter(r => r.phase==='phase1' && r.trial===trialNum)
        const sampG      = extractCalibSamples(trialRowsG)
        if (sampG.length > 20) {
          const beltG   = computeMLRPredictions(sampG, mlrWeightsRef.current!)
          const DS = 4
          const pacerPtsG: SignalPoint[] = sampG
            .filter((_,i) => i%DS===0)
            .map(s => ({ t: s.t - startMs, value: getPacerRadiusForTrial(s.t, startMs, baseMs, changedMs) }))
          const beltPtsG: SignalPoint[] = sampG
            .filter((_,i) => i%DS===0)
            .map((s,i) => ({ t: s.t - startMs, value: beltG[i*DS] }))
          const errG = medianPeakTimingError(
            sampG.map((s,i) => ({t: s.t, value: beltG[i]})),
            sampG.map(s => ({t: s.t, value: getPacerRadiusForTrial(s.t, startMs, baseMs, changedMs)})),
            baseMs * 0.6, beltLagMsRef.current
          )
          const condLabel = condition === 'SAME' ? 'No change' : condition === 'FASTER' ? 'Faster' : 'Slower'
          setLastTrialGraph({ pacerPts: pacerPtsG, beltPts: beltPtsG, scoreMs: errG, label: `T${trialNum} — ${condLabel}` })
        }

        // Silence handler so between-trial packets don't contaminate this trial's rows
        if (readAccChar.current)
          readAccChar.current.oncharacteristicvaluechanged = () => {}

        const nextIdx = idx + 1
        if (nextIdx >= phase1ListRef.current.length) {
          buildPhase1Review()
        } else {
          currentP1IndexRef.current = nextIdx
          setAppState('PHASE1_READY')
        }
      }, durationMs)
    }, READY_DELAY_MS)
  }

  const buildPhase1Review = () => {
    const entries: TrialReviewEntry[] = phase1ListRef.current.map((condition, idx) => {
      const trialNum  = idx + 1
      const periods   = p1PacerPeriods.current[idx]
      const trialRows = rawAccelRowsRef.current.filter(r => r.phase==='phase1' && r.trial===trialNum)
      const samp      = extractCalibSamples(trialRows)
      return buildReviewEntry(samp, mlrWeightsRef.current!, p1StartTimesRef.current[idx], periods.base, periods.changed, condition)
    })
    setPhase1Entries(entries)
    setAppState('PHASE1_REVIEW')
  }

  // ── QUEST staircase ───────────────────────────────────────────────────────

  const startQuest = () => {
    questFasterRef.current    = initQuestFaster()
    questSlowerRef.current    = initQuestSlower()
    questBlockRef.current     = []
    questTrialCountRef.current = 0
    questRecordsRef.current   = []
    filterState3Ref.current   = initFilterState3()
    livePredBufferRef.current = []
    packetCountRef.current    = 0
    setQuestFasterSD(questPosteriorSD(questFasterRef.current))
    setQuestSlowerSD(questPosteriorSD(questSlowerRef.current))
    setQuestFasterN(0); setQuestSlowerN(0)
    setAppState('QUEST_READY')
  }

  const nextQuestCondition = (): TrialCondition => {
    if (!questBlockRef.current.length) questBlockRef.current = buildQuestBlock()
    return questBlockRef.current.shift()!
  }

  const runQuestTrial = () => {
    const condition   = nextQuestCondition()
    const baseMs      = basePeriodMsRef.current

    let deltaRatio: number
    if (condition === 'FASTER') deltaRatio = questNextDelta(questFasterRef.current)
    else if (condition === 'SLOWER') deltaRatio = questNextDelta(questSlowerRef.current)
    else deltaRatio = 0

    const changedMs = condition === 'FASTER' ? baseMs * (1 - deltaRatio)
                    : condition === 'SLOWER' ? baseMs * (1 + deltaRatio)
                    : baseMs

    questCurrentCondRef.current  = condition
    questCurrentDeltaRef.current = deltaRatio
    const trialNum = ++questTrialCountRef.current
    setCurrentQuestTrialNum(trialNum)

    currentPhaseRef.current = 'quest'
    currentTrialRef.current = trialNum

    // Reset filter at each trial start — between-trial waits (rating screen)
    // leave the causal filter in an arbitrary state otherwise.
    filterState3Ref.current   = initFilterState3()
    livePredBufferRef.current = []

    if (readAccChar.current)
      readAccChar.current.oncharacteristicvaluechanged = makeLiveHandler('quest', trialNum)

    setTimeout(async () => {
      const startMs = Date.now()
      setPacerForTrial(startMs, baseMs, changedMs)

      setBlueCirclePhases([
        { duration: baseMs/1000,    iterations: 2 },
        { duration: changedMs/1000, iterations: 2 },
      ])
      setBlueCircleKey(k => k + 1)
      setAppState('QUEST_TRIAL_RUNNING')

      try { await serialPortWriter.current?.write('1\n') } catch {}

      const durationMs = 2 * baseMs + 2 * changedMs
      setTimeout(async () => {
        try { await serialPortWriter.current?.write('0\n') } catch {}
        clearPacer()
        await flushPending()
        if (readAccChar.current)
          readAccChar.current.oncharacteristicvaluechanged = () => {}
        setAppState('QUEST_RATING')
      }, durationMs)
    }, READY_DELAY_MS)
  }

  const handleQuestRating = async (response: TrialCondition, confidence: number, arousal: number) => {
    const condition  = questCurrentCondRef.current
    const deltaRatio = questCurrentDeltaRef.current
    const trialNum   = questTrialCountRef.current
    const correct    = response === condition

    // Update appropriate staircase
    if (condition === 'FASTER') {
      questFasterRef.current = questUpdate(questFasterRef.current, deltaRatio, correct)
      setQuestFasterSD(questPosteriorSD(questFasterRef.current))
      setQuestFasterN(questFasterRef.current.nTrials)
    } else if (condition === 'SLOWER') {
      questSlowerRef.current = questUpdate(questSlowerRef.current, deltaRatio, correct)
      setQuestSlowerSD(questPosteriorSD(questSlowerRef.current))
      setQuestSlowerN(questSlowerRef.current.nTrials)
    }

    const rec: QuestTrialRecord = {
      trialIndex: trialNum, direction: condition, deltaRatio, response, correct,
      confidence, arousal,
      posteriorMeanLog: condition === 'FASTER' ? questPosteriorMeanLog(questFasterRef.current)
                      : condition === 'SLOWER' ? questPosteriorMeanLog(questSlowerRef.current)
                      : 0,
      posteriorSD:      condition === 'FASTER' ? questPosteriorSD(questFasterRef.current)
                      : condition === 'SLOWER' ? questPosteriorSD(questSlowerRef.current)
                      : 0,
    }
    questRecordsRef.current.push(rec)
    if (fileHandlesRef.current) await appendQuestRow(fileHandlesRef.current.quest, rec)

    // Check stopping
    if (shouldStopQuest(questFasterRef.current, questSlowerRef.current) ||
        questExceededMaxTrials(questFasterRef.current, questSlowerRef.current)) {
      setAppState('QUEST_COMPLETE')
    } else {
      runQuestTrial()
    }
  }

  // ── Graceful save & quit ──────────────────────────────────────────────────

  const doSaveAndQuit = async () => {
    if (p1TrialTimerRef.current) clearTimeout(p1TrialTimerRef.current)
    if (naturalTimerRef.current) clearTimeout(naturalTimerRef.current)
    clearPacer()
    await flushPending()
    cleanupHardware()
    setShowQuitConfirm(false)
    setAppState('END')
  }

  const cleanupHardware = () => {
    readAccChar.current?.stopNotifications?.().catch(()=>{})
    heartRateChar.current?.stopNotifications?.().catch(()=>{})
    const cleanup = async () => {
      try { await serialPortWriter.current?.close(); await writableStreamClosed.current } catch {}
      try { await serialPort.current?.close() } catch {}
    }
    cleanup()
  }

  // ── Derived render flags ─────────────────────────────────────────────────

  const showBlueCircle = ([
    'CALIB_FIXATION','CALIB_BREATHE',
    'PHASE1_TRIAL_RUNNING',
    'QUEST_TRIAL_RUNNING',
  ] as AppState[]).includes(appState)

  const showSyncBar = ([
    'PHASE1_TRIAL_RUNNING','QUEST_TRIAL_RUNNING',
  ] as AppState[]).includes(appState)

  const showQuestProgress = ([
    'QUEST_READY','QUEST_TRIAL_RUNNING','QUEST_RATING',
  ] as AppState[]).includes(appState)

  const showSaveQuit = !(['AUTH','WAIT_FOR_BLUETOOTH','CONNECTING_BT','WAIT_FOR_COM','CONNECTING_COM','SETUP_FILES','END','ERROR'] as AppState[]).includes(appState)

  // ── Render per state ──────────────────────────────────────────────────────

  const renderUI = () => {
    switch (appState) {

      // Setup
      case 'AUTH':
        return (
          <AuthScreen
            onSubmit={(id, skipPhase1) => {
              setParticipantId(id)
              skipPhase1Ref.current = skipPhase1
              setAppState('WAIT_FOR_BLUETOOTH')
            }}
          />
        )

      case 'WAIT_FOR_BLUETOOTH':
        return <>
          <p style={{ textAlign:'center', maxWidth:520 }}>
            Put on the Polar H10 belt — connector centred on chest, electrodes moistened. Click when ready.
          </p>
          <button onClick={async () => {
            setAppState('CONNECTING_BT')
            try {
              await connectBluetooth(readAccChar, heartRateChar)
              setAppState('WAIT_FOR_COM')
            } catch {
              alert('Bluetooth connection failed. Please try again.')
              setAppState('WAIT_FOR_BLUETOOTH')
            }
          }}>Connect to Polar H10</button>
        </>

      case 'CONNECTING_BT':
        return <><LoadIcon /><p>Connecting to Polar H10…</p></>

      case 'WAIT_FOR_COM':
        return <>
          <p>Connect to the physio equipment COM port to enable trial triggers.</p>
          <button onClick={async () => {
            setAppState('CONNECTING_COM')
            try {
              const { port, writer, writableStreamClosed: wsc } = await getPortWriter()
              serialPortWriter.current     = writer
              serialPort.current           = port
              writableStreamClosed.current = wsc
              setAppState('SETUP_FILES')
            } catch {
              alert('COM port connection failed. Please try again.')
              setAppState('WAIT_FOR_COM')
            }
          }}>Connect to COM Port</button>
        </>

      case 'CONNECTING_COM':
        return <><LoadIcon /><p>Connecting to COM port…</p></>

      case 'SETUP_FILES':
        return <>
          <p style={{ textAlign:'center', maxWidth:480 }}>
            Choose a folder where data files will be saved continuously during the session.
          </p>
          <button onClick={async () => {
            try {
              const handles = await initFileStorage(participantId)
              fileHandlesRef.current = handles

              if (readAccChar.current) {
                readAccChar.current.oncharacteristicvaluechanged = () => {}
                await readAccChar.current.startNotifications()
              }
              if (heartRateChar.current) {
                heartRateChar.current.oncharacteristicvaluechanged = hrHandler
                await heartRateChar.current.startNotifications()
              }
              rawAccelRowsRef.current = []; rawHRRowsRef.current = []
              pendingAccelRef.current = []; pendingHRRef.current = []
              currentPhaseRef.current = 'init'; currentTrialRef.current = -1
              setAppState('CALIB_READY')
            } catch (e) {
              // User may have cancelled — offer fallback or retry
              if ((e as Error).name !== 'AbortError') alert('Could not open save folder. Please try again.')
              setAppState('SETUP_FILES')
            }
          }}>Choose Save Folder</button>
        </>

      // Calibration
      case 'CALIB_READY':
        return <>
          <p style={{ textAlign:'center', maxWidth:520 }}>
            <strong>Calibration</strong><br />
            A blue circle will expand on inhale and contract on exhale.
            Breathe along with it as closely as you can for {CALIB_CYCLES} cycles, then we'll check the belt signal quality.
            Sit upright and stay still.
          </p>
          <button onClick={startCalibSequence}>Begin calibration</button>
        </>

      case 'CALIB_FIXATION':
        return null

      case 'CALIB_BREATHE':
        return <p style={{ textAlign:'center', maxWidth:480 }}>Breathe in as the circle expands, out as it contracts.</p>

      case 'CALIB_FITTING':
        return <><LoadIcon /><p>Fitting belt model…</p></>

      case 'CALIB_REVIEW':
        return (
          <CalibReviewPanel
            pacerPts={calibReviewPacer} beltPts={calibReviewBelt}
            fitR={calibFitR} peakErrorMs={calibPeakError}
            modelLabel={calibModelLabel} lagMs={calibLagMs}
            onContinue={startNaturalBreathing}
            onRedo={startCalibSequence}
          />
        )

      // Natural breathing
      case 'NATURAL_BREATHING': {
        const elapsed = Math.round(NATURAL_BREATH_MIN_MS / 1000)
        return <>
          <p style={{ textAlign:'center', maxWidth:480 }}>
            <strong>Breathe normally</strong><br />
            Let your breathing relax — breathe at whatever pace feels natural.
            We'll measure your natural breathing rate over the next {elapsed}–{NATURAL_BREATH_MAX_MS/1000} seconds.
          </p>
          <button onClick={finishNaturalBreathing}>Done</button>
        </>
      }

      case 'NATURAL_BREATH_RESULT': {
        const detected    = naturalPeriodMs
        const detectedS   = detected ? (detected / 1000).toFixed(1) : null
        const detectedBPM = detected ? Math.round(60000 / detected) : null
        const defaultS    = DEFAULT_BASE_PERIOD_S.toFixed(1)

        const confirm = (periodMs: number) => {
          basePeriodMsRef.current = periodMs
          if (skipPhase1Ref.current) {
            startQuest()
          } else {
            startPhase1()
          }
        }

        // Normalise graph pts for display (belt signal has arbitrary scale)
        const vals = naturalGraphPts.map(p => p.value)
        const vMin = Math.min(...vals), vMax = Math.max(...vals)
        const vR   = Math.max(vMax - vMin, 1e-6)
        const tMin = naturalGraphPts.length ? naturalGraphPts[0].t : 0
        const normPts: SignalPoint[] = naturalGraphPts.map(p => ({
          t: p.t - tMin, value: (p.value - vMin) / vR,
        }))

        return <>
          <p style={{ textAlign:'center', maxWidth:480 }}>
            {detectedS
              ? <>Estimated natural breathing rate: <strong>{detectedBPM} breaths/min</strong> (~{detectedS} s per breath).</>
              : <>Could not detect a clear breathing rate — belt signal may be noisy. Please use the default or retry.</>
            }
          </p>

          {normPts.length > 2 && (
            <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:4 }}>
              <span style={{ fontSize:'0.7rem', color:'#555' }}>Belt signal during free breathing</span>
              <SignalGraph
                pacerPts={[]} beltPts={normPts}
                width={380} height={80}
              />
            </div>
          )}

          <div style={{ display:'flex', gap:12, flexWrap:'wrap', justifyContent:'center' }}>
            {detectedS && (
              <button onClick={() => confirm(detected!)}>
                Use my rate ({detectedS} s)
              </button>
            )}
            <button onClick={() => confirm(DEFAULT_BASE_PERIOD_S * 1000)}>
              Use default ({defaultS} s)
            </button>
            <button onClick={startNaturalBreathing} style={{ background:'transparent', border:'1px solid #444', color:'#888' }}>
              Retry
            </button>
          </div>
        </>
      }

      // Phase 1
      case 'PHASE1_READY': {
        const idx   = currentP1IndexRef.current
        const total = phase1ListRef.current.length
        return <>
          <p style={{ textAlign:'center' }}>
            <strong>Trial {idx+1} of {total}</strong><br />
            Breathe along with the circle. A rate change may or may not occur mid-way through.
          </p>
          <button onClick={runPhase1Trial}>Start trial {idx+1}</button>
          {lastTrialGraph && (
            <div style={{
              position: 'fixed', bottom: 18, left: 18,
              background: 'rgba(20,20,20,0.92)', borderRadius: 8,
              padding: '8px 10px', border: '1px solid #2a2a2a',
              backdropFilter: 'blur(4px)', zIndex: 200,
              display: 'flex', flexDirection: 'column', gap: 4,
            }}>
              <span style={{ fontSize: '0.65rem', color: '#555' }}>
                <span style={{ color: '#3498db' }}>●</span> pacer &nbsp;
                <span style={{ color: '#e67e22' }}>●</span> belt
              </span>
              <SignalGraph
                pacerPts={lastTrialGraph.pacerPts}
                beltPts={lastTrialGraph.beltPts}
                scoreMs={lastTrialGraph.scoreMs}
                width={220} height={70}
                label={lastTrialGraph.label}
              />
            </div>
          )}
        </>
      }

      case 'PHASE1_TRIAL_RUNNING': {
        const idx   = currentP1IndexRef.current
        const total = phase1ListRef.current.length
        return <p style={{ textAlign:'center' }}>Trial {idx+1} of {total} — breathe with the circle…</p>
      }

      case 'PHASE1_REVIEW':
        return (
          <Phase1ReviewPanel
            entries={phase1Entries}
            onContinue={startQuest}
            onRedo={() => startPhase1()}
          />
        )

      // QUEST
      case 'QUEST_READY':
        return <>
          <p style={{ textAlign:'center', maxWidth:520 }}>
            <strong>Staircase phase</strong><br />
            Breathe along with the circle as before. After each trial, indicate whether the pace
            changed — and if so, in which direction. Answer as accurately as you can.
          </p>
          <button onClick={runQuestTrial}>Begin</button>
        </>

      case 'QUEST_TRIAL_RUNNING':
        return <p style={{ textAlign:'center' }}>Trial {currentQuestTrialNum} — breathe with the circle…</p>

      case 'QUEST_RATING':
        return (
          <QuestRating trialNum={currentQuestTrialNum} onSubmit={handleQuestRating} />
        )

      case 'QUEST_COMPLETE':
        return <>
          <p style={{ textAlign:'center', maxWidth:480 }}>
            <strong>Staircase complete.</strong><br />
            Faster threshold: ~{(questNextDelta(questFasterRef.current) * basePeriodMsRef.current / 1000).toFixed(2)} s
            ({(questNextDelta(questFasterRef.current) * 100).toFixed(1)} %)<br />
            Slower threshold: ~{(questNextDelta(questSlowerRef.current) * basePeriodMsRef.current / 1000).toFixed(2)} s
            ({(questNextDelta(questSlowerRef.current) * 100).toFixed(1)} %)
          </p>
          <button onClick={async () => { await flushPending(); cleanupHardware(); setAppState('END') }}>
            Finish session
          </button>
        </>

      case 'END':
        return <p style={{ textAlign:'center' }}>Session complete. All data has been saved.<br />You may close this page.</p>

      case 'ERROR':
        return <><p>An unexpected error occurred.</p><button onClick={() => window.location.reload()}>Restart</button></>

      default:
        return null
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div style={{ display:'grid', gridTemplateRows:'auto 1fr', width:'100%', minHeight:'100vh' }}>

      <header style={{ display:'flex', alignItems:'center', justifyContent:'center', padding:'16px 20px', position:'relative' }}>
        <img src={logo} alt="" style={{ height:60, position:'absolute', left:20 }} />
        <h1 style={{ margin:0, textAlign:'center', fontSize:'1.4rem' }}>Controlled Breathing Study</h1>
      </header>

      <main style={{ position:'relative', display:'flex', flexDirection:'column', alignItems:'center', justifyContent:'center', gap:20, padding:20, minHeight:'60vh' }}>

        {showBlueCircle && <BlueCircle key={blueCircleKey} breathSpeeds={blueCirclePhases} />}

        <div style={{ position:'relative', zIndex:10, display:'flex', flexDirection:'column', alignItems:'center', gap:16, textAlign:'center' }}>
          {renderUI()}
        </div>

      </main>

      {showSyncBar        && <SynchronyBar quality={syncQuality} />}
      {showQuestProgress  && <QuestProgressBar fasterSD={questFasterSD} slowerSD={questSlowerSD} fasterN={questFasterN} slowerN={questSlowerN} />}
      {showSaveQuit       && <SaveQuitButton onClick={() => setShowQuitConfirm(true)} />}

      {/* Save & Quit confirmation modal */}
      {showQuitConfirm && (
        <div style={{
          position:'fixed', inset:0, background:'rgba(0,0,0,0.7)', zIndex:500,
          display:'flex', alignItems:'center', justifyContent:'center',
        }}>
          <div style={{ background:'#1a1a1a', borderRadius:10, padding:28, maxWidth:360, textAlign:'center', border:'1px solid #333' }}>
            <p style={{ margin:'0 0 20px' }}>Save all data collected so far and end the session?</p>
            <div style={{ display:'flex', gap:12, justifyContent:'center' }}>
              <button onClick={doSaveAndQuit}>Yes, save &amp; quit</button>
              <button onClick={() => setShowQuitConfirm(false)} style={{ background:'transparent', border:'1px solid #444', color:'#888' }}>Cancel</button>
            </div>
          </div>
        </div>
      )}

    </div>
  )
}

export default App
