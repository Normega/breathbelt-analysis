import { useEffect, useRef, useState } from 'react'
import { MIN_BASE_RADIUS, MAX_BASE_RADIUS, SYNC_GOOD, SYNC_FAIR } from '../../constants'
import { SignalPoint, TrialCondition, TrialReviewEntry, ModelLabel } from '../../functions'
import loadingIconImg from './assets/arrows.png'

// SVG assets for QuestRating
import snailSvg      from './assets/snail.svg'
import equalsSvg     from './assets/equals.svg'
import runnerSvg     from './assets/runner.svg'
import arousal1Svg   from './assets/arousal_1.svg'
import arousal2Svg   from './assets/arousal_2.svg'
import arousal3Svg   from './assets/arousal_3.svg'
import arousal4Svg   from './assets/arousal_4.svg'
import arousal5Svg   from './assets/arousal_5.svg'
import arousal6Svg   from './assets/arousal_6.svg'
import confidence1Svg from './assets/confidence_1.svg'
import confidence2Svg from './assets/confidence_2.svg'
import confidence3Svg from './assets/confidence_3.svg'
import confidence4Svg from './assets/confidence_4.svg'
import confidence5Svg from './assets/confidence_5.svg'
import confidence6Svg from './assets/confidence_6.svg'

type BreathSpeedAndCount = { duration: number; iterations: number }

// ---------------------------------------------------------------------------
// LoadIcon
// ---------------------------------------------------------------------------

export const LoadIcon = () => (
  <img src={loadingIconImg} alt="" style={{ width: '8vw', height: '8vw' }} className="loading" />
)

// ---------------------------------------------------------------------------
// AuthScreen
// ---------------------------------------------------------------------------

export const AuthScreen = ({ onSubmit }: { onSubmit: (id: string, skipPhase1: boolean) => void }) => {
  const [id, setId]     = useState('')
  const [skip, setSkip] = useState(false)
  const submit = () => { if (id.trim()) onSubmit(id.trim(), skip) }
  return (
    <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:16, maxWidth:400, width:'100%' }}>
      <h2 style={{ margin:0 }}>Participant Setup</h2>
      <p style={{ margin:0, textAlign:'center' }}>Enter a participant ID — used to name your data files.</p>
      <input
        type="text" value={id} onChange={e => setId(e.target.value)}
        onKeyDown={e => { if (e.key==='Enter') submit() }}
        placeholder="e.g. P001" autoFocus
        style={{ width:'100%', padding:'10px 14px', fontSize:'1rem', borderRadius:6, border:'1px solid #ccc', boxSizing:'border-box' }}
      />
      <label style={{ display:'flex', alignItems:'center', gap:8, fontSize:'0.8rem', color:'#666', cursor:'pointer' }}>
        <input type="checkbox" checked={skip} onChange={e => setSkip(e.target.checked)} />
        Skip Phase 1 practice (dev)
      </label>
      <button onClick={submit} disabled={!id.trim()} style={{ width:'100%', padding:12, fontSize:'1rem' }}>
        Continue
      </button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// BlueCircle  — pacing circle via Web Animations API
// ---------------------------------------------------------------------------

export const BlueCircle = ({ breathSpeeds, initialDelayMs=0 }: { breathSpeeds: BreathSpeedAndCount[], initialDelayMs?: number }) => {
  useEffect(() => {
    const keyframes = [
      { transform:'scale(0.5)', offset:0,   easing:'ease-in-out' },
      { transform:'scale(1.3)', offset:0.5, easing:'ease-in-out' },
      { transform:'scale(0.5)', offset:1,   easing:'ease-in-out' },
    ]
    breathSpeeds.forEach((phase, i) => {
      const delay = initialDelayMs + breathSpeeds.slice(0,i).reduce((s,p) => s + p.duration*p.iterations*1000, 0)
      document.getElementById('pulse-circle')?.animate(keyframes, {
        duration: phase.duration * 1000, iterations: phase.iterations, fill:'forwards', delay,
      })
    })
  }, [])

  return (
    <div style={{ zIndex:2, position:'absolute', top:0, left:0, width:'100%', height:'100%', display:'flex', alignItems:'center', justifyContent:'center', pointerEvents:'none' }}>
      <div id="pulse-circle" style={{
        width: `clamp(${MIN_BASE_RADIUS}px, 30vw, ${MAX_BASE_RADIUS}px)`,
        height:`clamp(${MIN_BASE_RADIUS}px, 30vw, ${MAX_BASE_RADIUS}px)`,
        borderRadius:'50%', border:'5px solid #3498db', background:'transparent', transform:'scale(0.5)',
      }} />
    </div>
  )
}

// ---------------------------------------------------------------------------
// SynchronyBar  — fixed bottom-centre, shows rolling Pearson r
// ---------------------------------------------------------------------------

export const SynchronyBar = ({ quality }: { quality: number }) => {
  const color = quality >= SYNC_GOOD ? '#2ecc71' : quality >= SYNC_FAIR ? '#f39c12' : '#e74c3c'
  const label = quality >= SYNC_GOOD ? 'Good sync' : quality >= SYNC_FAIR ? 'Fair sync' : 'Sync lost'
  const pct   = Math.round(quality * 100)

  return (
    <div style={{
      position:'fixed', bottom:18, left:'50%', transform:'translateX(-50%)',
      display:'flex', alignItems:'center', gap:10,
      background:'rgba(20,20,20,0.88)', borderRadius:20, padding:'5px 14px',
      border:'1px solid #2a2a2a', zIndex:200, backdropFilter:'blur(4px)',
    }}>
      <div style={{ width:110, height:7, background:'#2a2a2a', borderRadius:4, overflow:'hidden' }}>
        <div style={{ width:`${pct}%`, height:'100%', background:color, transition:'width 0.5s, background 0.4s' }} />
      </div>
      <span style={{ fontSize:'0.68rem', color:'#999', whiteSpace:'nowrap' }}>{label}</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// SaveQuitButton
// ---------------------------------------------------------------------------

export const SaveQuitButton = ({ onClick }: { onClick: () => void }) => (
  <button onClick={onClick} style={{
    position:'fixed', bottom:16, right:16,
    padding:'7px 14px', fontSize:'0.78rem',
    background:'#1e1e1e', border:'1px solid #383838',
    borderRadius:6, color:'#888', cursor:'pointer', zIndex:200,
  }}>
    Save &amp; Quit
  </button>
)

// ---------------------------------------------------------------------------
// SignalGraph  — SVG line graph, blue = pacer, amber = belt model
// ---------------------------------------------------------------------------

const GRAPH_DS = 8  // display every Nth point

export const SignalGraph = ({
  pacerPts, beltPts, scoreMs, width=300, height=80, label,
}: {
  pacerPts: SignalPoint[]
  beltPts:  SignalPoint[]
  scoreMs?: number
  width?:   number
  height?:  number
  label?:   string
}) => {
  const hasPacer = pacerPts.length >= 2
  const hasBelt  = beltPts.length  >= 2
  if (!hasPacer && !hasBelt) return (
    <div style={{ width, height, background:'#0d1117', borderRadius:4, display:'flex', alignItems:'center', justifyContent:'center' }}>
      <span style={{ color:'#444', fontSize:'0.7rem' }}>No data</span>
    </div>
  )

  const allPts = [...pacerPts, ...beltPts]
  const tMin = allPts[0].t, tMax = allPts[allPts.length-1].t
  const tR   = Math.max(tMax - tMin, 1)
  const PAD  = 4

  const bVals = hasBelt ? beltPts.map(p => p.value) : [0, 1]
  const bMin  = Math.min(...bVals), bMax = Math.max(...bVals)
  const bR    = Math.max(bMax - bMin, 1e-6)

  const toX  = (t: number)  => PAD + ((t - tMin) / tR) * (width - 2*PAD)
  const toYp = (v: number)  => height - PAD - v * (height - 2*PAD)         // pacer already 0–1
  const toYb = (v: number)  => height - PAD - ((v - bMin)/bR) * (height - 2*PAD)  // belt normalized

  const path = (pts: SignalPoint[], toY: (v:number)=>number, step=GRAPH_DS) =>
    pts.filter((_,i)=>i%step===0)
       .map((p,i)=>`${i===0?'M':'L'}${toX(p.t).toFixed(1)},${toY(p.value).toFixed(1)}`)
       .join(' ')

  const sc = scoreMs
  const scoreColor = sc===undefined||!isFinite(sc) ? '#555'
    : sc < 300 ? '#2ecc71' : sc < 600 ? '#f39c12' : '#e74c3c'

  return (
    <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:3 }}>
      {label && <span style={{ fontSize:'0.68rem', color:'#666' }}>{label}</span>}
      <svg width={width} height={height} style={{ background:'#0d1117', borderRadius:4, display:'block' }}>
        {hasBelt  && <path d={path(beltPts,  toYb)} stroke="#e67e22" strokeWidth="1.5" fill="none" opacity="0.9" />}
        {hasPacer && <path d={path(pacerPts, toYp)} stroke="#3498db" strokeWidth="2"   fill="none" opacity="0.9" />}
      </svg>
      {sc !== undefined && (
        <span style={{ fontSize:'0.68rem', color: scoreColor }}>
          {isFinite(sc) ? `${sc.toFixed(0)} ms` : 'N/A'}
        </span>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// CalibReviewPanel
// ---------------------------------------------------------------------------

const MODEL_NAMES: Record<ModelLabel, string> = {
  'mlr-wide':    'MLR wide-band',
  'mlr-tight':   'MLR tight-band',
  'mlr-wide-lp': 'MLR wide + smooth',
  'mlr-tight-lp':'MLR tight + smooth',
  'pca-wide':    'PCA wide-band',
  'pca-tight':   'PCA tight-band',
}

export const CalibReviewPanel = ({
  pacerPts, beltPts, fitR, peakErrorMs, modelLabel, lagMs, onContinue, onRedo,
}: {
  pacerPts:    SignalPoint[]
  beltPts:     SignalPoint[]
  fitR:        number
  peakErrorMs: number
  modelLabel:  ModelLabel
  lagMs:       number
  onContinue:  () => void
  onRedo:      () => void
}) => {
  const rPct   = Math.round(fitR * 100)
  const rColor = fitR >= 0.7 ? '#2ecc71' : fitR >= 0.4 ? '#f39c12' : '#e74c3c'
  const lagColor = Math.abs(lagMs) < 400 ? '#2ecc71' : Math.abs(lagMs) < 800 ? '#f39c12' : '#e74c3c'

  return (
    <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:16, maxWidth:520 }}>
      <h3 style={{ margin:0 }}>Calibration review</h3>
      <p style={{ margin:0, fontSize:'0.88rem', color:'#aaa', textAlign:'center' }}>
        <span style={{ color:'#3498db' }}>●</span> pacer &nbsp;
        <span style={{ color:'#e67e22' }}>●</span> belt model
      </p>

      <SignalGraph pacerPts={pacerPts} beltPts={beltPts} width={460} height={110} />

      <div style={{ display:'flex', gap:20, fontSize:'0.85rem', flexWrap:'wrap', justifyContent:'center' }}>
        <span>Fit: <strong style={{ color: rColor }}>{rPct}%</strong></span>
        <span>Lag: <strong style={{ color: lagColor }}>{lagMs > 0 ? '+' : ''}{lagMs.toFixed(0)} ms</strong></span>
        <span>Peak timing: <strong style={{ color: peakErrorMs<400?'#2ecc71':peakErrorMs<700?'#f39c12':'#e74c3c' }}>
          {isFinite(peakErrorMs) ? `${peakErrorMs.toFixed(0)} ms` : 'N/A'}
        </strong></span>
        <span style={{ color:'#666' }}>Model: <strong style={{ color:'#aaa' }}>{MODEL_NAMES[modelLabel]}</strong></span>
      </div>

      <div style={{ display:'flex', gap:12 }}>
        <button onClick={onContinue} disabled={fitR < 0.4}>✓ Looks good — continue</button>
        <button onClick={onRedo}>↺ Redo calibration</button>
      </div>
      {fitR < 0.4 && (
        <p style={{ margin:0, fontSize:'0.8rem', color:'#e74c3c' }}>
          Signal quality too low — please redo calibration.
        </p>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Phase1ReviewPanel — 3×3 grid of trial graphs
// ---------------------------------------------------------------------------

export const Phase1ReviewPanel = ({
  entries, onContinue, onRedo,
}: {
  entries:    TrialReviewEntry[]
  onContinue: () => void
  onRedo:     () => void
}) => {
  const condLabel: Record<TrialCondition,string> = { SAME:'Same', FASTER:'Faster', SLOWER:'Slower' }
  const condColor: Record<TrialCondition,string> = { SAME:'#888', FASTER:'#3498db', SLOWER:'#9b59b6' }

  return (
    <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:20, maxWidth:700 }}>
      <h3 style={{ margin:0 }}>Phase 1 complete — belt synchrony</h3>
      <p style={{ margin:0, fontSize:'0.82rem', color:'#aaa', textAlign:'center' }}>
        <span style={{ color:'#3498db' }}>●</span> pacer &nbsp;
        <span style={{ color:'#e67e22' }}>●</span> belt model &ensp;
        Score = median peak-timing error (ms)
      </p>

      <div style={{ display:'grid', gridTemplateColumns:'repeat(3,1fr)', gap:'14px 12px' }}>
        {entries.map((e, i) => (
          <div key={i} style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:4 }}>
            <span style={{ fontSize:'0.7rem', color: condColor[e.condition] }}>
              T{i+1} — {condLabel[e.condition]}
            </span>
            <SignalGraph pacerPts={e.pacerPts} beltPts={e.beltPts} scoreMs={e.scoreMs} width={196} height={64} />
          </div>
        ))}
      </div>

      <div style={{ display:'flex', gap:12, marginTop:4 }}>
        <button onClick={onContinue}>✓ Continue to staircase</button>
        <button onClick={onRedo}>↺ Redo Phase 1</button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// QuestRating — 3AFC (SVG icons) + 6-point confidence + 6-point arousal
// ---------------------------------------------------------------------------

// Speed-change icons: snail = SLOWER, equals = SAME, runner = FASTER
const SPEED_OPTIONS: { val: TrialCondition; src: string; label: string; color: string }[] = [
  { val: 'SLOWER', src: snailSvg,  label: 'Slower',    color: '#9b59b6' },
  { val: 'SAME',   src: equalsSvg, label: 'No change', color: '#888888' },
  { val: 'FASTER', src: runnerSvg, label: 'Faster',    color: '#3498db' },
]

const CONFIDENCE_SVGS = [confidence1Svg, confidence2Svg, confidence3Svg, confidence4Svg, confidence5Svg, confidence6Svg]
const AROUSAL_SVGS    = [arousal1Svg, arousal2Svg, arousal3Svg, arousal4Svg, arousal5Svg, arousal6Svg]

// Large 3-AFC icon button for speed direction
const SpeedButton = ({
  src, label, color, selected, onClick,
}: {
  src: string; label: string; color: string; selected: boolean; onClick: () => void
}) => (
  <button
    onClick={onClick}
    style={{
      display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 8,
      padding: '14px 18px', borderRadius: 10, cursor: 'pointer',
      border: selected ? `2px solid ${color}` : '2px solid #2a2a2a',
      background: selected ? `${color}1a` : '#131313',
      transition: 'all 0.15s',
    }}
  >
    <div style={{ width: 72, height: 72, borderRadius: 8, background: '#e8e8e8', display:'flex', alignItems:'center', justifyContent:'center' }}>
      <img src={src} alt={label} style={{ width: 60, height: 60, opacity: selected ? 1 : 0.5, transition: 'opacity 0.15s' }} />
    </div>
    <span style={{ fontSize: '0.78rem', color: selected ? color : '#666', fontWeight: selected ? 600 : 400 }}>{label}</span>
  </button>
)

// Small numbered SVG button for 6-point scales
const ScaleButton = ({
  src, index, color, selected, onClick,
}: {
  src: string; index: number; color: string; selected: boolean; onClick: () => void
}) => (
  <button
    onClick={onClick}
    aria-label={String(index)}
    style={{
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      padding: 6, borderRadius: 8, cursor: 'pointer',
      border: selected ? `2px solid ${color}` : '2px solid transparent',
      background: selected ? `${color}1a` : 'transparent',
      transition: 'all 0.15s',
    }}
  >
    <div style={{ width: 48, height: 48, borderRadius: 6, background: '#e8e8e8', display:'flex', alignItems:'center', justifyContent:'center' }}>
      <img src={src} alt={String(index)} style={{ width: 40, height: 40, objectFit:'contain', opacity: selected ? 1 : 0.45, transition: 'opacity 0.15s' }} />
    </div>
  </button>
)

export const QuestRating = ({
  trialNum, onSubmit,
}: {
  trialNum: number
  onSubmit: (response: TrialCondition, confidence: number, arousal: number) => void
}) => {
  const [response,   setResponse]   = useState<TrialCondition|null>(null)
  const [confidence, setConfidence] = useState<number|null>(null)
  const [arousal,    setArousal]    = useState<number|null>(null)

  const ready = response !== null && confidence !== null && arousal !== null

  return (
    <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:24, maxWidth:500 }}>
      <p style={{ margin:0, fontSize:'0.85rem', color:'#999' }}>Trial {trialNum} — rate your experience</p>

      {/* ── Speed direction — 3AFC ── */}
      <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:10 }}>
        <span style={{ fontSize:'0.78rem', color:'#666', letterSpacing:'0.04em', textTransform:'uppercase' }}>
          Did the breathing pace change?
        </span>
        <div style={{ display:'flex', gap:12 }}>
          {SPEED_OPTIONS.map(opt => (
            <SpeedButton
              key={opt.val}
              src={opt.src}
              label={opt.label}
              color={opt.color}
              selected={response === opt.val}
              onClick={() => setResponse(opt.val)}
            />
          ))}
        </div>
      </div>

      {/* ── Confidence — 6-point ── */}
      <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:8 }}>
        <span style={{ fontSize:'0.78rem', color:'#666', letterSpacing:'0.04em', textTransform:'uppercase' }}>
          How confident are you?
        </span>
        <div style={{ display:'flex', gap:4 }}>
          {CONFIDENCE_SVGS.map((src, i) => (
            <ScaleButton
              key={i}
              src={src}
              index={i + 1}
              color="#3498db"
              selected={confidence === i + 1}
              onClick={() => setConfidence(i + 1)}
            />
          ))}
        </div>
        <div style={{ display:'flex', justifyContent:'space-between', width:'100%', padding:'0 6px' }}>
          <span style={{ fontSize:'0.68rem', color:'#555' }}>Not at all</span>
          <span style={{ fontSize:'0.68rem', color:'#555' }}>Completely</span>
        </div>
      </div>

      {/* ── Arousal — 6-point ── */}
      <div style={{ display:'flex', flexDirection:'column', alignItems:'center', gap:8 }}>
        <span style={{ fontSize:'0.78rem', color:'#666', letterSpacing:'0.04em', textTransform:'uppercase' }}>
          How alert do you feel?
        </span>
        <div style={{ display:'flex', gap:4 }}>
          {AROUSAL_SVGS.map((src, i) => (
            <ScaleButton
              key={i}
              src={src}
              index={i + 1}
              color="#27ae60"
              selected={arousal === i + 1}
              onClick={() => setArousal(i + 1)}
            />
          ))}
        </div>
        <div style={{ display:'flex', justifyContent:'space-between', width:'100%', padding:'0 6px' }}>
          <span style={{ fontSize:'0.68rem', color:'#555' }}>Very drowsy</span>
          <span style={{ fontSize:'0.68rem', color:'#555' }}>Very alert</span>
        </div>
      </div>

      <button
        disabled={!ready}
        onClick={() => ready && onSubmit(response!, confidence!, arousal!)}
        style={{ marginTop:4, padding:'10px 32px', fontSize:'0.95rem', opacity: ready ? 1 : 0.4 }}
      >
        Confirm
      </button>
    </div>
  )
}

// ---------------------------------------------------------------------------
// QuestProgressBar
// ---------------------------------------------------------------------------

export const QuestProgressBar = ({
  fasterSD, slowerSD, fasterN, slowerN,
}: {
  fasterSD: number; slowerSD: number; fasterN: number; slowerN: number
}) => {
  const sdToWidth = (sd: number) => Math.max(0, Math.min(100, (1 - sd/0.3) * 100))
  const sdToColor = (sd: number) => sd < 0.10 ? '#2ecc71' : sd < 0.15 ? '#f39c12' : '#888'

  return (
    <div style={{
      position:'fixed', bottom:58, right:16,
      background:'rgba(20,20,20,0.88)', borderRadius:10, padding:'8px 14px',
      border:'1px solid #2a2a2a', zIndex:200, fontSize:'0.7rem', color:'#888',
      backdropFilter:'blur(4px)', display:'flex', flexDirection:'column', gap:5,
    }}>
      <span>Staircase convergence</span>
      {[
        { label:`Faster (n=${fasterN})`, sd:fasterSD },
        { label:`Slower (n=${slowerN})`, sd:slowerSD },
      ].map(({label, sd}) => (
        <div key={label} style={{ display:'flex', alignItems:'center', gap:7 }}>
          <span style={{ width:80 }}>{label}</span>
          <div style={{ width:70, height:5, background:'#222', borderRadius:3, overflow:'hidden' }}>
            <div style={{ width:`${sdToWidth(sd)}%`, height:'100%', background:sdToColor(sd), transition:'width 0.5s' }} />
          </div>
          <span style={{ color:sdToColor(sd) }}>{sd.toFixed(2)}</span>
        </div>
      ))}
    </div>
  )
}
