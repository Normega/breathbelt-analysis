import jsQuestPlus from 'jsquest-plus'
import { useRef } from 'react'
import {
  QUEST_LOG_MIN, QUEST_LOG_MAX, QUEST_N_STEPS,
  QUEST_SLOPE, QUEST_LAPSE, QUEST_GUESS,
  QUEST_CONVERGENCE_SD, QUEST_MIN_TRIALS_EACH,
  QUEST_PRIOR_MEAN_LOG, QUEST_PRIOR_SD,
} from '../constants'

function linspace(a, b, n) {
  return Array.from({ length: n }, (_, i) => a + (b - a) * i / (n - 1))
}

const stimSamples   = linspace(QUEST_LOG_MIN, QUEST_LOG_MAX, QUEST_N_STEPS)
const threshSamples = linspace(QUEST_LOG_MIN, QUEST_LOG_MAX, QUEST_N_STEPS)

const rawPrior = threshSamples.map(t =>
  Math.exp(-0.5 * Math.pow((t - QUEST_PRIOR_MEAN_LOG) / QUEST_PRIOR_SD, 2))
)
const priorSum    = rawPrior.reduce((a, b) => a + b, 0)
const threshPrior = rawPrior.map(v => v / priorSum)

function pCorrect(stim, threshold, slope, guess, lapse) {
  const tmp = slope * (stim - threshold)
  return (1 - lapse) * (guess + (1 - guess) * (1 - Math.exp(-Math.pow(10, tmp)))) + lapse * guess
}
function pWrongSame(stim, threshold, slope, guess, lapse) {
  return (1 - pCorrect(stim, threshold, slope, guess, lapse)) / 2
}
function pWrongOpposite(stim, threshold, slope, guess, lapse) {
  return (1 - pCorrect(stim, threshold, slope, guess, lapse)) / 2
}

function createStaircase(savedPosteriors) {
  const prior = savedPosteriors
    ? jsQuestPlus.set_prior([savedPosteriors, [1], [1], [1]])
    : jsQuestPlus.set_prior([threshPrior,     [1], [1], [1]])
  return new jsQuestPlus({
    psych_func:    [pWrongSame, pCorrect, pWrongOpposite],
    stim_samples:  [stimSamples],
    psych_samples: [threshSamples, [QUEST_SLOPE], [QUEST_GUESS], [QUEST_LAPSE]],
    priors:        prior,
  })
}

function posteriorMeanLog(sc) {
  const post = sc.normalized_posteriors
  if (!post) return QUEST_PRIOR_MEAN_LOG
  return threshSamples.reduce((a, t, i) => a + t * post[i], 0)
}

function posteriorSD(sc) {
  const post = sc.normalized_posteriors
  if (!post) return QUEST_CONVERGENCE_SD + 0.01
  const mean = posteriorMeanLog(sc)
  return Math.sqrt(threshSamples.reduce((a, t, i) => a + post[i] * Math.pow(t - mean, 2), 0))
}

function shuffled(arr) {
  const a = [...arr]
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]]
  }
  return a
}

export function useBeltQuestStaircases(savedState) {
  const scRef         = useRef(null)
  const blockQueueRef = useRef([])

  if (!scRef.current) {
    scRef.current = {
      faster: createStaircase(savedState?.faster?.normalized_posteriors ?? null),
      slower: createStaircase(savedState?.slower?.normalized_posteriors ?? null),
      // Per-staircase update counts (excludes SAME catch trials), restored from
      // savedState so the MIN_TRIALS_EACH floor is cumulative across resumed sessions.
      counts: {
        faster: savedState?.faster?.trials ?? 0,
        slower: savedState?.slower?.trials ?? 0,
      },
    }
  }

  function buildBlock() {
    const { faster, slower } = scRef.current
    const fasterSD   = posteriorSD(faster)
    const slowerSD   = posteriorSD(slower)
    const dominant   = fasterSD >= slowerSD ? 'faster' : 'slower'
    const other      = dominant === 'faster' ? 'slower' : 'faster'
    const sameContext = dominant

    return shuffled([dominant, dominant, other, other, 'same']).map(key => {
      if (key === 'same') {
        return { key: 'same', log10Delta: null, deltaSec: 0, sameContext }
      }
      const log10Delta = scRef.current[key].getStimParams()
      return { key, log10Delta, deltaSec: Math.pow(10, log10Delta), sameContext: null }
    })
  }

  function getNextTrial() {
    if (blockQueueRef.current.length === 0) {
      blockQueueRef.current = buildBlock()
    }
    return blockQueueRef.current.shift()
  }

  function recordResponse(key, responseKey, log10Delta) {
    // SAME catch trials — never update staircase
    if (key === 'same') {
      return { correct: responseKey === 'same', responseIndex: null }
    }
    let responseIndex
    if (responseKey === key)         responseIndex = 1  // correct
    else if (responseKey === 'same') responseIndex = 0  // wrong: said same
    else                             responseIndex = 2  // wrong: opposite
    scRef.current[key].update(log10Delta, responseIndex)
    scRef.current.counts[key] += 1
    return { correct: responseIndex === 1, responseIndex }
  }

  function getConvergence() {
    const { faster, slower } = scRef.current
    return {
      faster: { sd: posteriorSD(faster), meanDeltaSec: Math.pow(10, posteriorMeanLog(faster)) },
      slower: { sd: posteriorSD(slower), meanDeltaSec: Math.pow(10, posteriorMeanLog(slower)) },
    }
  }

  function allConverged() {
    const { faster, slower } = getConvergence()
    const { faster: fCount, slower: sCount } = scRef.current.counts
    // Floor: never declare convergence before each staircase has run
    // QUEST_MIN_TRIALS_EACH trials, even if the posterior SD dips below threshold early.
    if (fCount < QUEST_MIN_TRIALS_EACH || sCount < QUEST_MIN_TRIALS_EACH) return false
    return faster.sd < QUEST_CONVERGENCE_SD && slower.sd < QUEST_CONVERGENCE_SD
  }

  function serialise() {
    return {
      faster: { normalized_posteriors: scRef.current.faster.normalized_posteriors, trials: scRef.current.counts.faster },
      slower: { normalized_posteriors: scRef.current.slower.normalized_posteriors, trials: scRef.current.counts.slower },
    }
  }

  return { getNextTrial, recordResponse, getConvergence, allConverged, serialise }
}
