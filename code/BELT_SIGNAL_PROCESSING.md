# Polar H10 Belt — Respiratory Signal Processing

This document describes the full pipeline for extracting a respiratory signal from Polar H10 accelerometer data and fitting it to a sinusoidal pacer reference. It is intended as a standalone reference for applying these algorithms in new contexts (Python, offline analysis, etc.).

---

## Hardware & Raw Data

- **Device:** Polar H10 chest belt
- **Signal:** 3-axis accelerometer (X, Y, Z), 200 Hz, 16-bit signed integers scaled by /100
- **Primary respiratory axis:** Z (anterior-posterior chest movement), but all three axes are used together
- **Data format per sample:** `{ t_ms, x, y, z }` where `t` is wall-clock milliseconds

> **Do not integrate accelerometer data.** Double integration to displacement causes unbounded drift. Use bandpass-filtered acceleration directly.

---

## Filter Bank

All filters are 2nd-order Butterworth, implemented as cascaded second-order sections (SOS). Designed at fs = 200 Hz using `scipy.signal.butter`. Applied offline using zero-phase forward-backward filtering (`filtfilt`) to eliminate group delay.

### Wide Bandpass [0.1–1.0 Hz]

Passes the fundamental breathing frequency plus harmonics up to ~1 Hz. Can cause secondary peaks at 2× the breathing frequency (~0.5 Hz for a 4 s breath period).

```
Stage 0:  b = [0.00019593,  0.00039186,  0.00019593]
          a = [1.0,        -1.96405851,  0.96487768]

Stage 1:  b = [1.0,  -2.0,  1.0]
          a = [1.0,  -1.99576529,  0.99577694]
```

### Tight Bandpass [0.1–0.4 Hz]

Suppresses 2nd+ harmonics. Preferred when breathing frequency is slow (~0.25 Hz / 4 s per breath) and harmonic contamination is a concern.

```
Stage 0:  b = [0.00002206,  0.00004412,  0.00002206]
          a = [1.0,        -1.98985376,  0.98997540]

Stage 1:  b = [1.0,  -2.0,  1.0]
          a = [1.0,  -1.99673910,  0.99675182]
```

### Lowpass Post-smooth [0.6 Hz]

Optional single SOS applied to the MLR output to smooth remaining noise. Used in the `-lp` model variants.

```
b = [0.00008766,  0.00017531,  0.00008766]
a = [1.0,        -1.97334425,  0.97369487]
```

### Biquad implementation (direct form II transposed)

```python
def biquad_step(x, b0, b1, b2, a1, a2, state):
    # state = [d0, d1]
    y  = b0 * x + state[0]
    d0 = b1 * x - a1 * y + state[1]
    d1 = b2 * x - a2 * y
    return y, [d0, d1]
```

For two cascaded stages, feed the output of stage 0 into stage 1.

### Zero-phase filtering (filtfilt)

```python
import numpy as np
from scipy.signal import sosfiltfilt

# wide bandpass SOS (shape: [n_sections, 6])
wide_sos = np.array([
    [0.00019593, 0.00039186, 0.00019593, 1.0, -1.96405851, 0.96487768],
    [1.0,       -2.0,        1.0,        1.0, -1.99576529, 0.99577694],
])
tight_sos = np.array([
    [0.00002206, 0.00004412, 0.00002206, 1.0, -1.98985376, 0.98997540],
    [1.0,       -2.0,        1.0,        1.0, -1.99673910, 0.99675182],
])
lp_sos = np.array([
    [0.00008766, 0.00017531, 0.00008766, 1.0, -1.97334425, 0.97369487],
])

xf = sosfiltfilt(wide_sos, raw_x)
yf = sosfiltfilt(wide_sos, raw_y)
zf = sosfiltfilt(wide_sos, raw_z)
```

---

## Model Variants

Six model variants are evaluated; the best by Pearson R is selected.

| Label          | Bandpass | Post-smooth | Method |
|----------------|----------|-------------|--------|
| `mlr-wide`     | Wide     | No          | MLR    |
| `mlr-tight`    | Tight    | No          | MLR    |
| `mlr-wide-lp`  | Wide     | 0.6 Hz      | MLR    |
| `mlr-tight-lp` | Tight    | 0.6 Hz      | MLR    |
| `pca-wide`     | Wide     | No          | PCA→MLR|
| `pca-tight`    | Tight    | No          | PCA→MLR|

---

## MLR Model (Multiple Linear Regression)

Fits a linear combination of the three filtered axes to the pacer reference signal:

```
prediction(t) = bias + w_x * x_filt(t) + w_y * y_filt(t) + w_z * z_filt(t)
```

Solved via ordinary least squares: `w = (AᵀA)⁻¹ Aᵀy` where the design matrix has columns `[1, xf, yf, zf]`.

```python
import numpy as np

def fit_mlr(xf, yf, zf, target):
    A = np.column_stack([np.ones(len(xf)), xf, yf, zf])
    w, _, _, _ = np.linalg.lstsq(A, target, rcond=None)
    return w  # [bias, wx, wy, wz]

def predict_mlr(xf, yf, zf, w):
    return w[0] + w[1]*xf + w[2]*yf + w[3]*zf
```

---

## PCA Model

Uses only the first principal component of the three filtered axes as the predictor, then regresses it onto the pacer target. The resulting weights can be re-expressed in original-axis space as `weights = scalar_w * eigenvector`.

```python
def fit_pca_mlr(xf, yf, zf, target):
    X = np.column_stack([xf, yf, zf])
    X -= X.mean(axis=0)
    cov = X.T @ X
    # Top eigenvector via power iteration (or np.linalg.eigh)
    _, vecs = np.linalg.eigh(cov)
    ev = vecs[:, -1]          # largest eigenvalue
    pc1 = X @ ev              # scalar projection
    # Scalar regression
    A = np.column_stack([np.ones(len(pc1)), pc1])
    w, _, _, _ = np.linalg.lstsq(A, target, rcond=None)
    bias, scalar_w = w
    # Re-express as axis weights for uniform application at inference
    weights = scalar_w * ev
    return bias, weights      # prediction = bias + weights @ [xf, yf, zf]
```

---

## Pacer Reference Signal

The pacing circle follows a cosine waveform. The reference signal (normalized 0–1, 0 = exhale, 1 = inhale) is:

```
pacer(t) = (1 - cos(2π * (t - t_start) / period_ms)) / 2
```

For a two-phase trial (2 breaths at base rate, then 2 breaths at changed rate):

```python
def pacer_for_trial(t, trial_start, base_period, changed_period):
    phase2_start = trial_start + 2 * base_period
    if t <= phase2_start:
        return pacer(t, trial_start, base_period)
    else:
        return pacer(t, phase2_start, changed_period)
```

---

## Lag Estimation

The belt signal lags behind the pacer due to physical chest movement inertia. Estimated by cross-correlation: shift the belt prediction forward in time and find the shift that maximises Pearson R against the pacer reference.

```python
def estimate_lag_ms(pred, ref, sample_dt_ms, max_lag_ms=1500):
    max_shift = int(max_lag_ms / sample_dt_ms)
    best_r, best_shift = -1, 0
    for shift in range(max_shift + 1):
        n = len(pred) - shift
        if n < 20:
            continue
        r = pearsonr(pred[shift:shift+n], ref[:n])[0]
        if r > best_r:
            best_r, best_shift = r, shift
    return best_shift * sample_dt_ms  # positive = belt lags pacer
```

Typical lag: 200–600 ms. Apply by shifting the pacer reference when computing synchrony quality.

---

## Quality Metrics

### 1. Pearson R (calibration fit)

```python
from scipy.stats import pearsonr
r, _ = pearsonr(belt_prediction, pacer_reference)
```

Thresholds: Good ≥ 0.70, Fair ≥ 0.40, Poor < 0.40.

### 2. Median Peak Timing Error (ms)

Finds peaks in both belt and pacer signals; computes the median absolute time difference between each pacer peak and its nearest belt peak (after lag correction).

```python
from scipy.signal import find_peaks

def median_peak_timing_error(belt_pts, pacer_pts, min_sep_ms, lag_ms=0):
    belt_times  = find belt peaks, shift left by lag_ms
    pacer_times = find pacer peaks
    errors = []
    for pp in pacer_times:
        nearest = min(belt_times, key=lambda bt: abs(bt - pp))
        err = abs(nearest - pp)
        if err < min_sep_ms * 0.75:
            errors.append(err)
    return np.median(errors) if errors else np.inf
```

Thresholds (approximate): Good < 300 ms, Fair 300–600 ms, Poor > 600 ms.

---

## Natural Breathing Period Estimation

Applied to a free-breathing window (10–20 s) to estimate the participant's natural breath period.

1. Apply chosen MLR model to get belt signal
2. Normalize 0–1
3. Find local maxima with minimum separation of 0.6 × expected period, threshold > 0.40 normalized amplitude
4. Compute inter-peak intervals; keep those in [2000, 8000] ms range
5. Return median interval

```python
def estimate_breath_period(signal_pts, min_period_ms=2000, max_period_ms=8000):
    # signal_pts: list of (t_ms, value) normalized 0-1
    peaks = []
    for i in range(2, len(signal_pts) - 2):
        t, v = signal_pts[i]
        is_max = (v > signal_pts[i-1][1] and v > signal_pts[i-2][1] and
                  v > signal_pts[i+1][1] and v > signal_pts[i+2][1])
        if is_max and v > 0.40:
            if not peaks or t - peaks[-1] > min_period_ms * 0.6:
                peaks.append(t)
    intervals = [peaks[i+1] - peaks[i] for i in range(len(peaks)-1)
                 if min_period_ms <= peaks[i+1] - peaks[i] <= max_period_ms]
    return np.median(intervals) if intervals else None
```

---

## Full Offline Pipeline Summary

```python
# 1. Load raw accel rows: columns [t_ms, x, y, z]
# 2. Apply filtfilt bandpass to each axis
# 3. Fit MLR (or PCA→MLR) weights against pacer reference
# 4. Apply weights to get belt prediction
# 5. Optional: apply LP post-smooth (0.6 Hz filtfilt)
# 6. Estimate lag via cross-correlation
# 7. Compute Pearson R and median peak timing error as quality metrics
# 8. Store weights; apply same weights to all subsequent trial data

def process_session(calib_rows, pacer_start_ms, period_ms):
    t   = calib_rows['t_ms'].values
    x, y, z = calib_rows[['x','y','z']].values.T
    target  = pacer(t, pacer_start_ms, period_ms)

    results = {}
    for variant in ['wide', 'tight']:
        sos     = wide_sos if variant == 'wide' else tight_sos
        xf, yf, zf = [sosfiltfilt(sos, s) for s in [x, y, z]]
        w       = fit_mlr(xf, yf, zf, target)
        pred    = predict_mlr(xf, yf, zf, w)
        r       = pearsonr(pred, target)[0]
        results[f'mlr-{variant}'] = (w, r, variant)
        pred_lp = sosfiltfilt(lp_sos, pred)
        r_lp    = pearsonr(pred_lp, target)[0]
        results[f'mlr-{variant}-lp'] = (w, r_lp, variant)  # same weights, LP at inference

    best_label = max(results, key=lambda k: results[k][1])
    best_w, best_r, best_variant = results[best_label]
    lag_ms = estimate_lag_ms(predict_mlr(*filter_axes(x,y,z,best_variant), best_w), target, dt_ms)
    return best_w, best_label, best_r, lag_ms
```

---

## Notes

- All filtering should use `filtfilt` (zero-phase) for offline analysis. The app uses a causal biquad during live data collection only for sync quality estimation — calibration and trial scoring always use offline `filtfilt`.
- `Math.pow()` is used throughout the TypeScript source instead of `**` due to a Vite/esbuild compatibility issue. Python code can use `**` freely.
- Calibration data collection must begin exactly when the pacing circle appears — not during instruction screens — to avoid timing misalignment in the regression.
