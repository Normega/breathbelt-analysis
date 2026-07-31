import { useEffect, useRef, useCallback } from 'react'
import AvatarBreathPacer from '../../EbbAndFlow/components/AvatarBreathPacer'
import { useBreathCycle } from '../../EbbAndFlow/useBreathCycle'
import CalibReviewPanel from './CalibReviewPanel'
import { BASE_BREATH_SPEED_S } from '../constants'

const BASE_MS = BASE_BREATH_SPEED_S * 1000

// ── CalibrationScreen ──────────────────────────────────────────────────────
//
// Drives the 4-state calibration flow:
//
//   FIXATION  — avatar frozen, brief pause before animation
//               caller has already called startCalibration()
//   BREATHE   — avatar breathing for 4 cycles at BASE speed
//               beginCalibCollection() called exactly when animation begins
//   FITTING   — spinner while fitBestModel() runs in the hook
//   REVIEW    — CalibReviewPanel with quality metrics
//   FAILED    — error + retry
//
// No OrangeCircle / BeltSyncRing shown at any point during calibration.
// The avatar IS the pacer. Collection timing is precise because
// beginCalibCollection() is called in the same tick as the avatar animation start.

const FIXATION_DELAY_MS = 800  // brief pause before animation — matches READY_DELAY_MS

export default function CalibrationScreen({
  calibPhase,
  calibReviewData,
  avatarProps,
  breathPeriodMs = BASE_MS,
  startCalibration,
  beginCalibCollection,
  acceptCalibration,
  redoCalibration,
}) {
  const { getPhase, startBreath, reset } = useBreathCycle()
  const controlRef      = useRef(null)
  const animStartedRef  = useRef(false)
  const avatarSize      = 240

  // When calibPhase enters FIXATION, wait briefly then start animation + collection
  useEffect(() => {
    if (calibPhase !== 'FIXATION') {
      animStartedRef.current = false
      return
    }
    if (animStartedRef.current) return
    animStartedRef.current = true

    const t = setTimeout(() => {
      // Timestamp captured here — exactly when animation is about to begin
      const calibStartMs = Date.now()
      reset()
      controlRef.current?.resumeAnimation?.()
      beginCalibCollection(calibStartMs, breathPeriodMs)
    }, FIXATION_DELAY_MS)

    return () => clearTimeout(t)
  }, [calibPhase, beginCalibCollection, breathPeriodMs, reset])

  // Drive avatar through 4 cycles during BREATHE
  const didRunBreaths = useRef(false)
  useEffect(() => {
    if (calibPhase !== 'BREATHE') { didRunBreaths.current = false; return }
    if (didRunBreaths.current) return
    didRunBreaths.current = true

    let cancelled = false
    ;(async () => {
      for (let i = 0; i < 4; i++) {
        if (cancelled) return
        await startBreath(breathPeriodMs)
      }
    })()

    return () => { cancelled = true }
  }, [calibPhase, breathPeriodMs, startBreath])

  const avatarPaused = calibPhase === 'FIXATION' || calibPhase === 'NONE'
  const showAvatar   = !['REVIEW', 'FAILED', 'COMPLETE'].includes(calibPhase)

  return (
    <div
      className="flex flex-col items-center gap-6 px-6 py-8"
      style={{ maxWidth: 520, margin: '0 auto' }}
    >
      {/* Avatar — only shown during connection/fixation/breathe/fitting */}
      {showAvatar && (
        <div style={{ position: 'relative', width: avatarSize, height: avatarSize }}>
          <div style={{ position: 'relative', zIndex: 2 }}>
            <AvatarBreathPacer
              {...avatarProps}
              scaleAmplitude={0.25}
              getPhase={getPhase}
              controlRef={controlRef}
              paused={avatarPaused}
              size={avatarSize}
            />
          </div>
        </div>
      )}

      {/* NONE — ready screen */}
      {calibPhase === 'NONE' && (
        <CalibReady onStart={startCalibration} />
      )}

      {/* FIXATION — brief pre-animation pause */}
      {calibPhase === 'FIXATION' && (
        <p className="text-center" style={{ color: 'var(--tx2)', fontSize: 'var(--fs-body-sm)' }}>
          Get ready to breathe with the avatar…
        </p>
      )}

      {/* BREATHE — live calibration collection */}
      {calibPhase === 'BREATHE' && (
        <p className="text-center" style={{ color: 'var(--tx2)', fontSize: 'var(--fs-body)' }}>
          Breathe in as the avatar expands, out as it contracts.
          <br />
          <span style={{ color: 'var(--tx3)', fontSize: 'var(--fs-body-sm)' }}>
            4 breaths — stay still
          </span>
        </p>
      )}

      {/* FITTING — async model selection */}
      {calibPhase === 'FITTING' && (
        <div className="flex flex-col items-center gap-3">
          <div
            style={{
              width: 32, height: 32, borderRadius: '50%',
              border: '3px solid var(--bd)',
              borderTopColor: 'var(--pk)',
              animation: 'spin 0.8s linear infinite',
            }}
          />
          <p style={{ color: 'var(--tx2)', fontSize: 'var(--fs-body-sm)' }}>
            Fitting belt model…
          </p>
          <style>{`@keyframes spin { to { transform: rotate(360deg) } }`}</style>
        </div>
      )}

      {/* REVIEW — quality metrics + accept/redo */}
      {calibPhase === 'REVIEW' && calibReviewData && (
        <CalibReviewPanel
          {...calibReviewData}
          onContinue={acceptCalibration}
          onRedo={redoCalibration}
        />
      )}

      {/* FAILED — signal too weak */}
      {calibPhase === 'FAILED' && (
        <CalibFailed onRedo={redoCalibration} />
      )}
    </div>
  )
}

// ── Sub-screens ───────────────────────────────────────────────────────────

function CalibReady({ onStart }) {
  return (
    <>
      <div className="text-center" style={{ maxWidth: 400 }}>
        <p style={{ color: 'var(--tx)', fontSize: 'var(--fs-body)', marginBottom: 8 }}>
          The avatar will breathe at a steady pace for <strong>4 breaths</strong>.
          Follow along — breathe in as it expands, out as it contracts.
        </p>
        <p style={{ color: 'var(--tx2)', fontSize: 'var(--fs-body-sm)' }}>
          Sit upright and stay still. After 4 breaths the app will fit a belt signal model
          and show you the quality.
        </p>
      </div>
      <button
        onClick={onStart}
        className="px-6 py-3 rounded-xl font-semibold"
        style={{ background: 'var(--pk)', color: '#fff', fontSize: 'var(--fs-body)' }}
      >
        Begin calibration
      </button>
    </>
  )
}

function CalibFailed({ onRedo }) {
  return (
    <>
      <p className="text-center" style={{ color: '#c0392b', fontSize: 'var(--fs-body)' }}>
        Calibration failed — signal too weak to fit a model.
        <br />
        <span style={{ color: 'var(--tx2)', fontSize: 'var(--fs-body-sm)' }}>
          Check that the belt electrodes are wet and the strap is snug against the skin.
        </span>
      </p>
      <button
        onClick={onRedo}
        className="px-5 py-3 rounded-xl font-semibold"
        style={{ background: 'var(--pk)', color: '#fff', fontSize: 'var(--fs-body)' }}
      >
        Retry calibration
      </button>
    </>
  )
}
