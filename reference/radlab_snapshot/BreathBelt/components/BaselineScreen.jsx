import { useEffect, useRef, useState } from 'react';
import AvatarBreathPacer from '../../EbbAndFlow/components/AvatarBreathPacer';
import { useBreathCycle } from '../../EbbAndFlow/useBreathCycle';
import BeltSyncRing from './BeltSyncRing';
import { estimateBreathPeriodMs } from '../breathUtils';

const SAMPLE_MS = 40;

// ── COM trigger vocabulary (baseline-level) ───────────────────────────────
// Pre-session:  triggerStart='2'  triggerEnd='3'
// Post-session: triggerStart='8'  triggerEnd='9'
// Session start ('1') and end ('0') are fired from BreathBelt.jsx around
// the pre/post baseline respectively — not from this component.

export default function BaselineScreen({
  phase,           // 'READY' | 'RECORDING' | 'COMPLETE'
  title,
  durationMs,
  breathValueRef,
  sendTrigger,
  currentPhaseRef,
  currentTrialRef,
  phaseLabel,
  triggerStart,    // COM code to send at recording start  (e.g. '2' or '8')
  triggerEnd,      // COM code to send at recording end    (e.g. '3' or '9')
  isSimMode = false,
  onStart,
  onComplete,      // (periodMs: number | null) => void
}) {
  // In sim mode, compress the recording to 4 s to keep the automated run fast.
  const effectiveDurationMs = isSimMode ? 4000 : durationMs;
  const [elapsed, setElapsed] = useState(0);
  const timerRef    = useRef(null);
  const intervalRef = useRef(null);
  const sampleRef   = useRef(null);
  const samplesRef  = useRef([]);
  const { getPhase } = useBreathCycle();
  const avatarSize  = 240;

  // Sim mode: auto-trigger onStart() after a short delay when in READY state.
  useEffect(() => {
    if (!isSimMode || phase !== 'READY') return;
    const t = setTimeout(() => { onStart(); }, 500);
    return () => clearTimeout(t);
  }, [phase, isSimMode]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (phase !== 'RECORDING') return;

    currentPhaseRef.current = phaseLabel;
    currentTrialRef.current = -1;
    samplesRef.current = [];

    sendTrigger(triggerStart);

    sampleRef.current = setInterval(() => {
      samplesRef.current.push({ t: Date.now(), value: breathValueRef.current ?? 0 });
    }, SAMPLE_MS);

    const start = Date.now();
    intervalRef.current = setInterval(() => {
      setElapsed(Math.min(Date.now() - start, effectiveDurationMs));
    }, 500);

    timerRef.current = setTimeout(async () => {
      clearInterval(sampleRef.current);
      clearInterval(intervalRef.current);
      await sendTrigger(triggerEnd);
      currentPhaseRef.current = 'idle';
      const periodMs = estimateBreathPeriodMs(samplesRef.current);
      onComplete(periodMs);
    }, effectiveDurationMs);

    return () => {
      clearInterval(sampleRef.current);
      clearInterval(intervalRef.current);
      clearTimeout(timerRef.current);
    };
  }, [phase]); // eslint-disable-line react-hooks/exhaustive-deps

  const secondsLeft = Math.ceil((effectiveDurationMs - elapsed) / 1000);
  const progress    = elapsed / effectiveDurationMs;

  return (
    <div className="flex flex-col items-center gap-6 px-6 py-8"
      style={{ maxWidth: 480, margin: '0 auto' }}>

      <div style={{ position: 'relative', width: avatarSize, height: avatarSize }}>
        <BeltSyncRing breathValueRef={breathValueRef} avatarSize={avatarSize} />
        <div style={{ position: 'relative', zIndex: 2 }}>
          <AvatarBreathPacer
            scaleAmplitude={0.25}
            getPhase={getPhase}
            paused={true}
            size={avatarSize}
          />
        </div>
      </div>

      {phase === 'READY' && (
        <>
          <div className="text-center">
            <p style={{ color: 'var(--tx)', fontSize: 'var(--fs-body)', marginBottom: 8, fontWeight: 600 }}>
              {title}
            </p>
            <p style={{ color: 'var(--tx2)', fontSize: 'var(--fs-body-sm)' }}>
              Sit comfortably and breathe naturally for {effectiveDurationMs / 1000} seconds.
              The avatar will stay still. The orange ring shows your belt signal.
            </p>
          </div>
          <button onClick={onStart} className="px-6 py-3 rounded-xl font-semibold"
            style={{ background: 'var(--pk)', color: '#fff', fontSize: 'var(--fs-body)' }}>
            Begin recording
          </button>
        </>
      )}

      {phase === 'RECORDING' && (
        <>
          <ProgressArc progress={progress} secondsLeft={secondsLeft} />
          <p className="text-center" style={{ color: 'var(--tx2)', fontSize: 'var(--fs-body-sm)' }}>
            Breathe naturally. Recording in progress.
          </p>
        </>
      )}

      {phase === 'COMPLETE' && (
        <p className="text-center" style={{ color: 'var(--tx)', fontSize: 'var(--fs-body)' }}>
          {title} complete.
        </p>
      )}
    </div>
  );
}

function ProgressArc({ progress, secondsLeft }) {
  const r = 40, cx = 50, cy = 50;
  const circumference = 2 * Math.PI * r;
  return (
    <div className="flex flex-col items-center gap-2">
      <svg width={100} height={100} viewBox="0 0 100 100">
        <circle cx={cx} cy={cy} r={r} fill="none" stroke="var(--bd)" strokeWidth={6} />
        <circle cx={cx} cy={cy} r={r} fill="none"
          stroke="rgba(255,140,60,0.8)" strokeWidth={6}
          strokeDasharray={`${circumference * progress} ${circumference}`}
          strokeLinecap="round" transform={`rotate(-90 ${cx} ${cy})`} />
      </svg>
      <span style={{ fontFamily: 'Space Mono', fontSize: 'var(--fs-mono-md)', color: 'var(--tx2)' }}>
        {secondsLeft}s
      </span>
    </div>
  );
}
