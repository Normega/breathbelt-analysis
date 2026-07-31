# BreathBelt: Comparing an Accelerometer Chest Strap Against a Stretch Respiration Belt

Pre-registration draft. Thresholds marked **[SIM]** are to be set by the power simulation. Items marked **[NEEDS INPUT]** require information not yet available.

---

# 1. Methods

## 1.1 Design

Within-participant instrument comparison. Every participant wears both respiration sensors simultaneously for a single session, so the two devices record the same breaths under identical conditions. A visual pacer provides a third, independently known reference for breathing rate during the paced blocks.

## 1.2 Participants

Recruited through the university SONA portal, from either the course-credit or the paid pool.

**Eligibility.** Participants had to be comfortable attending to their own breathing and answering questions about mental health. Exclusions at screening: asthma, other chronic respiratory illness, or a cardiovascular condition.

**Pre-session instructions.** Avoid heavy meals, caffeine, and drugs or medication within 30 minutes of the session. No other scheduling constraints.

**Sample size.** To be determined by simulation using the design parameters in Section 5. **[SIM]**

**Exclusions.** No participant is excluded a priori on the basis of poor performance or poor signal. Participants who adhere poorly to the pacer, or who calibrate poorly, are informative: the question is whether that poor adherence appears similarly on both devices. Exclusion applies only to incomplete data, defined as a session missing usable signal from either device, or missing the trial-level records needed to align them. Flagged but retained cases are described in Section 5.2.

## 1.3 Equipment

**Accelerometer belt.** Polar H10 chest strap, worn directly against the skin. Connects to the study software over Bluetooth Low Energy through a Chrome browser. Provides three-axis acceleration and heart rate.

**Stretch belt.** BioPac system: MP160 acquisition unit with a BN-RSPEC BioNomadix Respiration and ECG wireless system. The transmitter is worn by the participant and the receiver module feeds the MP160. Worn over the participant's clothing.

There is no RSP100C amplifier in this setup and therefore no operator-configurable gain or filter stage. The BioNomadix system's bandwidth is fixed in hardware, so the only signal conditioning before digitisation is whatever that hardware imposes. This matters for preprocessing: it is the sole anti-alias protection ahead of decimation, so decimation is performed with an explicit anti-alias filter rather than by taking every Nth sample.

**Pacer.** A visual pacing stimulus, an avatar circle that expands and contracts, coded directly into the study software. Participants inhale as the circle expands and exhale as it contracts.

**Synchronisation.** The study software sends numeric event codes to the BioPac trigger channel through a parallel port interface at each event boundary. Two seat positions are supported (left and right); the seat used is recorded per session.

**Belt order.** The Polar H10 is fitted first, against the skin. The BioPac belt is then fitted over clothing. Both are worn continuously for the whole session. Order is fixed and not counterbalanced, so device differences are confounded with placement (skin versus over-clothing, inner versus outer). This is addressed in the limitations.

## 1.4 Procedure

### Arrival and setup

1. The Polar H10 is fitted against the skin, then the BioPac belt over clothing.
2. BioPac recording begins.
3. The Polar H10 is paired to the study software in a Chrome browser.
4. A trigger verification cascade is sent and confirmed on the BioPac channel.
5. Participant completes a compensation form, choosing course credit or payment.
6. Participant completes the pre-session mood check-in (Section 1.5).

### Breath task

Five blocks, run consecutively in one session.

Blocks are numbered 1 to 5 throughout. Note that the recorded data does **not** use this numbering: the accelerometer files label blocks 3 and 4 as `phase2` and `phase3`, and `belt_trials.phase` codes them 2 and 3. The mapping is fixed and is given in Section 1.6.

**Block 1: Calibration.** The participant follows the pacer for four breath cycles at a 4 second period, after a 1 second fixation hold. Roughly 19 seconds in total. This block establishes how each participant's chest movement projects onto the accelerometer's three axes, which depends on body shape, posture, and exactly how the strap sits. Nothing is measured about the participant here; the block exists to derive the transformation used to turn three-axis acceleration into a single breathing signal.

At the end of the block the participant is shown their reconstructed breathing signal plotted against the pacer, with a fit score, and may accept it or repeat the block.

**Block 2: Free breathing 1 (120 s).** The participant breathes normally with no pacer displayed. This block is ecological: it tests whether the accelerometer recovers natural, unpaced breathing.

**Block 3: Fixed-rate paced breathing.** Nine trials, three at each of three conditions. Each trial is four breaths: the first two always at the 4 second baseline period, the last two at the condition period. Conditions are 3 seconds (faster), 4 seconds (unchanged), and 5 seconds (slower). Participants make no response in this block. It provides a three-way comparison at known rates, across pacer, stretch belt, and accelerometer.

**Change magnitude.** The imposed change is plus or minus 25% *of the baseline period*: 4000 ms becomes 3000 ms or 5000 ms. The software records this as `proportion_mag = (condition_period - 4000) / 4000`, taking values -0.25, 0, and +0.25.

This is deliberately stated in period rather than rate, because the two are not interchangeable and H3 concerns rate. A symmetric change in period is **asymmetric in rate**: 15 breaths per minute becomes 20 (an increase of 33%) or 12 (a decrease of 20%). Analyses of rate dependence use the realised rate, not the nominal plus or minus 25%.

**Trial order.** The nine trials are a fixed set (three same, three faster, three slower) shuffled by Fisher-Yates independently for each participant. This is randomisation without replacement within participant. It is **not** counterbalancing: there is no rotation of orders across participants and no constraint on run lengths, so condition order is not balanced against position by design. With nine trials and three conditions, order effects are absorbed into participant-level variance rather than controlled.

**Block 4: Adaptive staircase.** An adaptive procedure estimates each participant's threshold for detecting a change in breathing rate. Two independent staircases run interleaved, one for rate increases and one for rate decreases.

Each trial is four breaths: the first two always at the 4 second baseline period, the last two shifted faster or slower by the amount the staircase currently proposes. After each trial the participant reports:

- whether the rate got faster, got slower, or stayed the same,
- how confident they are in that judgement,
- how alert they feel.

Trials are delivered in shuffled blocks of five: two trials on whichever staircase is currently less certain, two on the other, and one catch trial with no change. Catch trials never update either staircase.

The block ends when both staircases are sufficiently certain (posterior standard deviation below 0.10 log units) and each has contributed at least 10 updating trials, or at a hard cap of 60 trials, whichever comes first. Trials are participant-initiated, so block duration varies.

**Block 5: Free breathing 2 (120 s).** Identical to Block 2. Tests whether agreement between the devices degrades over the course of wearing them.

### Questionnaires

Immediately after the post block, participants repeat the mood check-in, then complete, in this fixed order:

| Instrument | Content | Scale |
|---|---|---|
| Positive and Negative Affect Schedule | Extent to which feeling words apply right now | 1 to 5, very slightly or not at all, to extremely |
| Patient Health Questionnaire, 4-item | How often bothered by each problem over 2 weeks | 0 to 3, not at all, to nearly every day |
| Multidimensional Assessment of Interoceptive Awareness, version 2, brief form | How often each statement applies in daily life | 0 to 5, never, to always |
| Body Awareness and Responsiveness Questionnaire, revised | Agreement with each statement | 0 to 3, completely disagree, to completely agree |
| General Self-Efficacy Scale | Agreement with statements about handling challenges | 1 to 4, not at all true, to exactly true |
| Demographics | Age, gender, racialised identity, subjective social status via ladder placement | Mixed |

### Wrap-up

Debrief form, equipment removal, compensation within one week. Total session length approximately 40 to 60 minutes.

## 1.5 Rating scales

**Mood check-in (pre and post).** Two bipolar visual analogue ratings on 1 to 7 scales, positioned on the two diagonals of the affect circumplex:

- How good or energised do you feel? (sad to excited)
- How settled or on-edge do you feel? (calm to tense)

**Coding.** Each rating is centred on its neutral point of 4 and scaled by 3, placing it on [-1, +1]:

- `PA = (pos_rating - 4) / 3`, running -1 sad to +1 excited
- `NA = (neg_rating - 4) / 3`, running -1 calm to +1 tense

Because the two items lie on the two diagonals of the circumplex, valence and arousal are a 45 degree rotation of that pair. The software stores the rotated coordinates as `composite_x` and `composite_y`. Note that stored `composite_y` is **positive for high arousal**; any plot drawn in screen coordinates must negate it, or alert responses render in the calm quadrant.

**Mixedness.** Reported as Griffin's ambivalence index over the positive parts of the two ratings:

```
p = max(0, PA);  n = max(0, NA)
ambivalence = (p + n) / 2 - |p - n|
```

This peaks only when both dimensions are elevated **and** similar, which is the mixed-feelings construct. Values are clamped at 0 per response before averaging, not after: a consistently one-sided respondent scores -0.5, so averaging first and clamping second would collapse every summary to zero.

The exported `ambivalence_mag` column is **not** used. It is the Euclidean distance between the two selected points, which measures overall intensity rather than mixedness: a maximally cheerful and maximally relaxed response (7 positive, 3 negative) scores the highest value in the data on it, while being not mixed at all. Griffin's index correctly scores that response 0.

**Confidence (each Block 4 trial).** Six-point scale, anchored "no idea" to "certain".

**Alertness (each Block 4 trial).** Six-point scale, anchored "very tired" to "very alert". The item is worded in the software as activation, and indexes the arousal construct.

## 1.6 Data recording and synchronisation

**Stretch belt.** Recorded continuously at 2000 Hz for the whole session, alongside a derived heart rate channel and the trigger channel. The trigger channel idles at value 240 between pulses.

**Accelerometer.** Three-axis acceleration sampled at approximately 203 Hz and delivered over Bluetooth in packets of 36 samples, roughly every 177 ms. Each packet carries a timestamp corresponding to the last sample in the packet. Heart rate is delivered separately at 1 Hz. Every sample is written to a continuous session file tagged with the current block and trial.

**Event codes.** Sent to the BioPac trigger channel at each boundary: session start, block start and end for each of the five blocks, trial start, and trial end. A condition-onset code was deliberately removed from the software because emitting it disrupted pacer animation timing, which is the more critical requirement. The condition boundary within each trial is instead taken from the software's own trial record, where it is defined as trial start plus two baseline breaths.

**Block numbering in the data.** The exposition numbers blocks 1 to 5. The recorded files do not. The mapping is fixed:

| Block | Name | Accelerometer `phase` label | `belt_trials.phase` |
|---|---|---|---|
| 1 | Calibration | `calib_fixation`, `calib_breathe` | not applicable |
| 2 | Free breathing 1 | `baseline` | not applicable |
| 3 | Fixed-rate paced | `phase2` | 2 |
| 4 | Adaptive staircase | `phase3` | 3 |
| 5 | Free breathing 2 | `post_baseline` | not applicable |

Blocks 3 and 4 are therefore off by one from the `phase2` and `phase3` labels. `inter_trial` and `idle` also occur as accelerometer phase labels and belong to no block.

**Session clock.** The stretch belt has no absolute clock, only time from the start of recording. The two recordings are aligned by matching trial-start event codes to the software's trial-onset times in recording order, then fitting a linear correction across all trials to absorb accumulated divergence between the two clocks.

**Pacer signal.** The pacer position is deterministic: a sine at a known period, anchored to a known onset time. It is reconstructed analytically from the software's trial records rather than read from the recorded data.

**Amplifier.** No configurable amplifier stage exists: the BN-RSPEC BioNomadix system has fixed hardware bandwidth. **[NEEDS INPUT]** the datasheet bandwidth, to be cited rather than measured.

**AcqKnowledge template.** The acquisition template defines 17 channels at 2000 Hz: two respiration, two ECG, eight digital trigger lines, one derived trigger channel, two heart rate and two respiration rate calculation channels. The template governs display and derived channels only; the two respiration channels are stored raw in Volts and are not filtered by it.

---

## 1.7 Internal pilot and sample size

At the point this pre-registration was written, 17 participants had completed the full session. No outcome from those sessions has been examined.

Rather than discard them or guess at the variance parameters needed to set a sample size, they are declared an **internal pilot**. Their data are used to estimate nuisance variance only. They remain in the confirmatory sample. Using interim data to re-estimate a nuisance variance, without examining the quantities under test, has negligible effect on the false positive rate, and is a recognised design rather than an informal look.

The guarantee only holds if the restriction is real. It is enforced by script rather than by intention: a single extraction routine computes the permitted quantities, discards everything else before returning, and refuses to write output containing anything outside the list below. Participant-level values are destroyed inside the function that computes them. The pilot sample is fixed in advance and is not extended after output is seen.

### Extracted

Nuisance parameters. None appears in any decision rule in Section 5.

- Between-participant standard deviation of each participant's own mean breath-duration bias
- Within-participant standard deviation of breath-level duration differences
- Between-participant standard deviation of the breath-depth bias
- Between-participant standard deviation of each breathing-variability measure
- Distribution of Block 4 trial counts
- Distribution of breath counts
- Distribution of calibration fit
- Distribution of estimated device lag
- Distribution of alignment residuals
- Frequency with which each of the six calibration models is selected

### Blocked

Each is an effect entering a confirmatory decision rule. None is computed, or is computed only inside a function that discards it.

| Blocked quantity | Protects |
|---|---|
| Mean breath-duration bias | H1 |
| Proportion of breaths matched between devices | H2 |
| Onset timing difference between devices | H2 |
| Duration or depth error broken down by imposed rate | H3 |
| Any error relative to the pacer | H4 |
| Any agreement coefficient: intraclass, concordance, or kappa | H2, H5, H7 |
| Pre-to-post change in agreement | H6 |
| Any alertness and adherence relationship | H8 |
| Any correlation | H1 to H8, EH1, EH4 |
| Any agreement quantity split by selected calibration model | EH3 |
| Any per-participant value or identifier | All |

Two calls warrant note. Calibration fit and device lag are extracted: neither enters a decision rule, both are preprocessing parameters the simulation needs, and the lag distribution is separately required for the sanity check in Section 5.1. Conversely, the proportion of breaths matched between devices is blocked despite being useful, because it is the recall component of H2's test statistic; H2's expected match rate is instead set from a stated smallest effect of interest.

### Sequence

1. Correct the preprocessing pipeline so calibration weights are fitted against the reconstructed pacer. The extraction script refuses to run on files fitted against the stretch belt, since those absorb participant-specific variance and would understate the between-participant standard deviation, yielding an optimistic sample size.
2. Fix the pilot sample and record the participant list here.
3. Run the extraction. Read only its report.
4. Set the equivalence margins, deriving the breath-duration margin from the downstream classification in H7 where possible.
5. Simulate power across a grid of sample sizes and fix a provisional target.
6. Re-estimate the variance once, at a pre-specified interim sample size, and adjust the target within a pre-specified cap.

### Precision this affords

A variance estimate from 17 participants is usable but not sharp. The sampling distribution of a standard deviation on 16 degrees of freedom gives a 95% interval running from 0.74 to 1.52 times the true value. Because the required sample size scales with the variance, that interval widens to roughly 0.55 to 2.32 times the point estimate: a provisional target of 60 is consistent with a true requirement anywhere between 33 and 139.

The interim re-estimation at step 6 exists for this reason, and matters more than precision in the initial estimate.

### Assumed bias

Power for an equivalence test is highest when the true bias is exactly zero, so assuming zero yields an optimistic sample size. The simulation instead assumes a non-zero bias of one quarter of the equivalence margin. This is fixed in advance.

**[NEEDS INPUT]** Pilot participant list, to be recorded here before extraction.

---

# 2. Research Questions

The confirmatory aim is the instrument comparison. A secondary, wholly exploratory set of questions uses the task to examine interoception, and does not depend on the device comparison. The interoception questions are not powered for confirmatory testing and are labelled as such throughout.

## Confirmatory: instrument comparison

**RQ1.** Do the two belts agree about how long each breath takes?

**RQ2.** Do the two belts pick out the same individual breaths, at the same moments in time?

**RQ3.** Is agreement better for breath timing than for breath depth, and does that difference get worse as breathing gets faster?

**RQ4.** How accurately does each belt recover the breathing rate the pacer actually asked for, and is one belt better than the other?

**RQ5.** Do the two belts agree about how much a person's breathing varies over time?

**RQ6.** Does agreement between the belts hold up across a session, or does it degrade as the belts are worn?

**RQ7.** Would the conclusions we draw from this study change if we had used one belt rather than the other?

**RQ8.** Does how alert a person reports feeling predict how closely they follow the pacer, and does that relationship look the same on both belts?

## Exploratory: interoception

The sample affords no useful power for between-participant association tests, each of which has one observation per person. These questions ask only whether the estimated relationships are **directionally consistent** with prior work. They are labelled ERQ to keep them out of the confirmatory sequence.

**ERQ1.** Are people's ability to detect breathing-rate changes, their confidence in those judgements, and their self-reported body awareness related in the way prior work suggests?

**ERQ2.** Does self-reported body awareness relate to how people actually breathe, in rate, variability, or pacer adherence?

ERQ1 was considered for confirmatory testing and dropped. It rests on a predicted near-zero association, which requires an equivalence test, and bounding a correlation at plus or minus 0.20 needs over 200 participants. Testing the contrast between the two correlations directly is cheaper but still reaches only about 0.74 power at 100 participants under generous assumptions. Neither is feasible here, so ERQ1 is reported descriptively.

---

# 3. Hypotheses

Each hypothesis states a prediction in plain language. The tests and decision rules are in Section 5. Terms in bold are defined in Section 4.

## Aim 1

**H1. Breath duration agrees (primary).**
Serves RQ1. **Breath duration** measured by the accelerometer and by the stretch belt agree closely enough to treat them as interchangeable, within a margin set in advance. Tested separately in each block and pooled.

**H2. The belts find the same breaths, at the same times.**
Serves RQ2. Where the stretch belt marks a **breath onset**, so does the accelerometer, and vice versa, with few additions or omissions. Among breaths both devices find, the onsets line up closely. The number of breaths counted per block agrees.

This is a stricter test than H1: two devices can produce the same average breath duration while disagreeing about which breaths occurred.

**H3. Timing survives rate changes; depth does not.**
Serves RQ3. An accelerometer measures acceleration, which for a given chest movement grows with the square of breathing frequency. Breath duration carries no such dependence. We therefore predict:

- (a) Agreement on **breath duration** is unaffected by the imposed rate.
- (b) Agreement on **breath depth** gets systematically worse as breathing gets faster.

If (a) fails, the claim that a calibration performed at a single rate generalises to other rates is falsified.

**H4. Neither belt tracks the pacer better than the other.**
Serves RQ4. The gap between what a belt measures and what the pacer commanded is equivalent across the two belts. This is a separate question from H1: two belts can agree perfectly with each other and both be wrong.

That gap reflects two things at once: how accurately the device measures breathing, and how closely the participant actually followed the pacer. For a single device the two cannot be separated. They do separate in the comparison between devices, because both record the same breaths, so the adherence component is common to both and cancels. The between-belt comparison is therefore the hypothesis test; the per-belt figures are descriptive only.

**H5. The belts agree about breathing variability.**
Serves RQ5. Measures of breath-to-breath variability computed from the two devices agree during the free-breathing blocks.

**H6. Agreement is stable across the session, except where signal quality drops.**
Serves RQ6. Agreement does not decline from the pre to the post free-breathing block. Where it does decline, the decline is predicted by the **signal quality index**, not by time elapsed. In other words, disagreement reflects the belt shifting or the participant moving, not the device degrading with wear.

**H7. Conclusions do not depend on which belt we used (decisive).**
Serves RQ7. The study's substantive outputs are unchanged when the accelerometer is substituted for the stretch belt. Specifically: classifications of whether a participant's breathing followed the cued direction agree between devices, and any trial-level effects using breath duration as a predictor give equivalent coefficients.

**H8. Alertness predicts adherence, equally on both belts.**
Serves RQ8. Within a participant, trials on which they report feeling more alert are trials on which they follow the pacer more closely. This relationship is equivalent whether adherence is measured from the accelerometer or the stretch belt.

## Exploratory

**EH1. Body awareness relates to how people breathe.**
Serves ERQ2. Higher **interoceptive sensibility** is associated with slower, less variable breathing and closer pacer adherence. Pacer adherence is included here rather than in a separate hypothesis.

**EH2. Waveform shape is best recovered at ordinary breathing rates.**

The two devices do not measure the same physical quantity. The stretch belt measures chest circumference, which is displacement. The accelerometer measures acceleration, which is the second derivative of displacement. For a roughly sinusoidal breath, differentiating twice does two things: it scales the amplitude by the square of frequency, and it distorts the waveform shape, because faster components of the waveform are amplified more than slower ones. The accelerometer signal therefore looks sharper and more peaked, and the asymmetry between inhale and exhale is not preserved.

Comparing waveform shape is not a fair comparison until that derivative relationship is undone. Once it is, we predict that shape agreement is best at ordinary breathing rates and worse at both extremes, for opposite reasons:

- **When breathing is fast:** the squared-frequency scaling amplifies the sharp parts of the waveform and any motion artifact; the heartbeat's own mechanical signature, at around 1 Hz, starts to intrude.
- **When breathing is slow:** the same scaling shrinks the acceleration, so a slow deep breath produces very little acceleration relative to sensor noise, and drift dominates.

The prediction is an inverted U across imposed rate.

This is the only hypothesis that tests waveform shape rather than summary statistics. It matters for anything derived from the shape of a breath rather than its timing: the ratio of inhale to exhale duration, flow estimates, and the onset detection that H2 depends on.

**EH3. The chosen calibration model may act as a hidden moderator.**
Calibration selects, per participant, whichever of six candidate transformations best reconstructs the pacer. Different participants therefore run under different transformations. We will describe how often each is selected, and test whether the selected model predicts subsequent agreement between the belts. Not a focal hypothesis.

**EH4. Directional consistency with prior findings.**
Serves ERQ1. Prior work suggests that accuracy and self-report come apart while confidence and self-report do not. Two parts:

- **(a)** **Detection threshold** correlates weakly or not at all with self-reported **interoceptive sensibility**.
- **(b)** **Mean confidence** correlates substantially with **interoceptive sensibility**.

Part (a) is a prediction of near-zero association. A non-significant result cannot support it, and the sample needed to bound the correlation properly is far beyond what is feasible here, so (a) is assessed descriptively by asking whether the estimated parameter is near zero.

Four commitments, fixed in advance:

- Both correlations are reported with confidence intervals, alongside the contrast between them.
- Directional consistency is stated explicitly: for (b), a positive point estimate; for (a), whether the confidence interval falls inside, overlaps, or excludes a region of practical equivalence of plus or minus 0.20.
- Results are described as consistent or inconsistent with the prior pattern. No claim is made that the prior finding has been reproduced, in either direction.
- A non-significant threshold-by-sensibility correlation will **not** be read as evidence of dissociation.

---

# 4. Indices

Definitions for every term used in Section 3, with its source.

## 4.1 Derived signals

| Term | Definition | Source | Status |
|---|---|---|---|
| **Stretch belt signal** | Respiration channel from the BioPac amplifier, recorded at 2000 Hz, decimated to 25 Hz. The active channel is identified by variance, not by slot position, because slot order does not reliably map to seat. | BioPac acquisition file | Defined |
| **Accelerometer signal** | Single breathing waveform reconstructed from three-axis acceleration using participant-specific weights. Axes are band-pass filtered from 0.05 to 1.0 Hz, combined by the calibrated weights, then low-pass filtered at 0.6 Hz. All filters are Butterworth of **design order 4**, applied forwards and then backwards so no phase shift is introduced. See Section 5.1 for the full specification. | Accelerometer session file plus calibration weights | Defined |
| **Calibration weights** | Coefficients from a multiple linear regression predicting the reconstructed pacer position from the three band-passed acceleration axes, fitted on the Block 1 calibration window only. Refitted offline; the weights computed live in the software are used only for the participant's on-screen preview. | Fitted from Block 1, approximately 3,900 samples | Defined |
| **Pacer signal** | Sine wave at the commanded period, anchored to the recorded block or trial onset. Reconstructed analytically. The recorded pacer column is empty in the data files and is not used. | Software trial records | Defined |
| **Common time base** | Both signals resampled to a uniform 25 Hz grid. Accelerometer sample times are reconstructed by back-assigning from each packet timestamp at 4.916 ms intervals, the empirically measured sample period. | Preprocessing | Defined |
| **Device lag** | Time offset between the two signals, estimated by shifting one against the other until agreement peaks. Searched over plus or minus 2000 ms. | Preprocessing | Defined |

## 4.2 Breath-level measures

| Term | Definition | Source | Status |
|---|---|---|---|
| **Breath onset** | Trough in the filtered breathing signal, marking the start of an inhale. Detected independently in each device's signal. | Both devices | Defined |
| **Breath duration** | Interval between consecutive breath onsets, in milliseconds. Also referred to as breath period. | Both devices | Defined |
| **Breath depth** | Peak-to-trough amplitude of each breath cycle, in each device's native units. Compared after within-participant standardisation, since the units are not commensurable. | Both devices | Defined |
| **Breath count** | Number of detected onsets in a defined window. | Both devices | Defined |
| **Breathing variability** | Three measures over each free-breathing block: the spread of breath durations relative to their mean; the typical size of the change from one breath to the next; and the predictability of the sequence. | Both devices | Defined |
| **Waveform shape agreement** | Frequency-resolved agreement between the two signals across the respiratory band, after undoing the derivative relationship. See Section 5.11. | Both devices | Defined |

## 4.3 Task measures

| Term | Definition | Source | Status |
|---|---|---|---|
| **Commanded period** | Period the pacer was instructed to display: 4000 ms for the first two breaths of every trial; 3000, 4000, or 5000 ms in Block 3; 4000 ms plus or minus the staircase magnitude in Block 4. | Software trial records | Defined |
| **Change magnitude** | Size of the rate change on a Block 4 trial, in seconds, sampled from 46 logarithmically spaced levels between 0.1 and 2.0 s. | Software trial records | Defined |
| **Direction judgement** | Three-option response after each Block 4 trial: faster, slower, or no change. | Software trial records | Defined |
| **Detection threshold** | Change magnitude a participant can detect reliably, estimated separately for the faster and slower staircases by an adaptive Bayesian procedure. Prior centred on 0.5 s with a standard deviation of 0.25 log units; underlying psychometric function has a slope of 3.5, a guessing rate of one in three, and a lapse rate of 0.02. | Staircase posterior | Defined |
| **Pacer adherence** | Closeness between the participant's actual breathing and the commanded pacer, per trial. Two forms: continuous, the correlation between the device signal and the reconstructed pacer; and categorical, whether the observed change in breath duration went in the cued direction. | Derived, both devices | Defined |
| **Direction correct** | Categorical adherence, ported from the prior study's analysis script. Mean duration of breaths 3 and 4 minus mean duration of breaths 1 and 2, compared in sign to the cued change. | Derived, both devices | Defined |
| **Confidence** | Six-point rating after each Block 4 trial, "no idea" to "certain". | Software trial records | Defined |
| **Mean confidence** | Participant's average confidence across all Block 4 trials. | Derived | Defined |
| **Alertness** | Six-point rating after each Block 4 trial, "very tired" to "very alert". Indexes arousal. | Software trial records | Defined |

## 4.4 Self-report measures

| Term | Definition | Source | Status |
|---|---|---|---|
| **Interoceptive sensibility** | Total score on the brief Multidimensional Assessment of Interoceptive Awareness, version 2. Subscale analyses are exploratory and uncorrected. | Questionnaire | Defined |
| **Pre-session and post-session affect** | Valence and arousal coordinates derived from the two diagonal mood ratings, plus the degree of mixedness. | Mood check-in | Defined |

## 4.5 Quality and control measures

| Term | Definition | Source | Status |
|---|---|---|---|
| **Signal quality index** | Explained variance ratio. Over a rolling 15 s window of the band-passed three-axis acceleration, the proportion of total movement variance that lies along the calibrated breathing direction. Bounded 0 to 1. Falls when the participant shifts posture, the strap slips, or non-respiratory movement intrudes. Not recorded during sessions; computed offline from raw acceleration and the calibration weights. Tuning to be performed on these data. **[SIM]** | Computed offline | Defined, to be tuned |
| **Selected calibration model** | Which of six candidate transformations won calibration for each participant: multiple regression or principal component analysis, on a wide or narrow filter band, with or without a smoothing step. | Session record | Defined |
| **Calibration fit** | Correlation between the reconstructed accelerometer signal and the pacer during Block 1. | Session record and refit | Defined |
| **Alignment residual** | Per-trial discrepancy between the two devices' clocks after linear correction. Diagnostic. | Preprocessing | Defined |

## 4.6 Expected observation counts

From the one fully processed participant, for design purposes.

| Unit | Count per participant |
|---|---|
| Block 3 trials | 9, fixed |
| Block 4 trials | 25 observed; range 20 to 60 by stopping rule |
| Paced breaths | Approximately 136 |
| Free-breathing breaths | Approximately 60, across both blocks |
| Total breaths | Approximately 196 |
| Free-breathing signal | 240 s |
| Total streaming time | Approximately 20 minutes |

---

# 5. Data Analysis Plan

Written to supply the quantities a power simulation needs: the estimand, the unit of analysis, the number of observations available, and the parameters that must be assumed. Section 5.12 collects those parameters.

## 5.1 Preprocessing

Fixed in advance and applied identically to every participant.

1. **Load and downsample.** Stretch belt from 2000 Hz to 25 Hz. Accelerometer resampled to the same 25 Hz grid.
2. **Reconstruct accelerometer sample times.** Back-assign from each packet timestamp at 4.916 ms per sample, the measured rate. This replaces the nominal 5.000 ms, which introduces about 2.9 ms of error at the start of each packet.
3. **Align the two recordings.** Match trial-start event codes to software trial onsets in recording order. Discard every event code occurring before the session-start code, which removes the setup verification cascade. Fit a linear correction across all matched trials. Extract each trial anchored on its own event code, so alignment error does not accumulate.
4. **Filter.** Band-pass each acceleration axis from 0.05 to 1.0 Hz.

   **Filter specification.** Stated precisely because "fourth-order, applied forwards and backwards" is ambiguous about whether the order is counted before or after the two passes.

   - **Design order 4.** A 4th-order Butterworth is designed, then applied twice, once forwards and once backwards.
   - Two passes give **zero phase distortion** and an **effective magnitude response of order 8**, i.e. roughly 48 dB per octave in the stopband, since the squared magnitude response of a 4th-order filter is that of an 8th-order one.
   - In R: `signal::butter(n = 4, ...)` followed by `signal::filtfilt`. The reported order is the argument to `butter()`, not the effective order.
   - The same convention applies to the 0.6 Hz low-pass and to the narrow 0.10 to 0.4 Hz band used by the tight calibration model variants.

   This differs from the live software, which applies 2nd-order biquad sections under the same forwards-and-backwards scheme and is therefore effectively 4th order. The offline specification above is authoritative; the live filters exist only to drive the participant's on-screen preview.

   **Edge handling.** Every zero-phase filter pass is preceded by odd-reflection padding of 15 seconds at each end, and the padding is discarded afterwards. This is not cosmetic. The calibration window is 16 s while the 0.05 Hz high-pass corner has a 20 s period, so an unpadded filter spends the entire window settling: in synthetic testing an unpadded pass recovered an injected 320 ms device lag as 160 ms and failed to recover the breathing direction at all. The live software pads for the same reason. `signal::filtfilt` in R does not pad by default, so the padding is applied explicitly.
5. **Calibrate.** Fit multiple linear regression weights predicting the reconstructed pacer from the three band-passed axes, using the Block 1 window only. Apply to the whole session, then low-pass at 0.6 Hz.
6. **Correct for lag.** Estimate device lag by cross-correlation over plus or minus 2000 ms, per participant, on the Block 1 window. Apply the same lag throughout the session.
7. **Detect breath onsets.** Independently in each device's signal, using the same trough-detection rule.
8. **Compute the signal quality index** in rolling 15 s windows.

**Circularity control.** Calibration weights are fitted against the pacer, never against the stretch belt. This keeps the stretch belt out of the accelerometer's construction, so agreement between the two devices is not inflated by shared fitting. A version fitted against the stretch belt on the pre free-breathing block will be reported as a sensitivity analysis and interpreted as an upper bound only.

**Lag applied consistently.** The software computes some trial-level agreement measures with lag correction and others without. All measures are recomputed offline with lag correction applied uniformly, so that no comparison contrasts a corrected quantity against an uncorrected one.

**Lag sanity check.** Device lag reflects signal transduction and processing, so it should be positive and of the order of a few hundred milliseconds. Any participant whose estimated lag is negative, or exceeds 1000 ms, is flagged and inspected before analysis. The distribution of lags across participants is reported.

**Filter authority.** The offline parameters above are authoritative. They differ from the settings used in the live software, which exist only to drive the participant's on-screen preview.

## 5.2 Flagging without exclusion

The following are recorded and reported, and used as covariates or moderators where specified, but do not trigger exclusion:

- Low calibration fit
- Low signal quality index
- Poor pacer adherence
- Large alignment residuals
- Staircase that did not converge before the trial cap

Exclusion applies only to incomplete data: a session missing usable signal from either device, or missing the trial records required for alignment.

## 5.3 H1: Breath duration agreement

**Estimand.** Mean difference in breath duration between devices, and its limits of agreement.

**Unit.** Individual breath, matched between devices. Approximately 196 per participant. Multiple observations per participant, so repeated-measures methods are used throughout.

**Primary test.** Two one-sided tests procedure. Two separate one-sided tests ask whether the mean difference is meaningfully greater than the lower margin, and whether it is meaningfully less than the upper margin. Rejecting both supports equivalence. The margin is the primary quantity the power simulation must resolve. **[SIM]**

**Supporting descriptives**, reported but not part of the decision rule:

- Lin's concordance correlation coefficient, which combines how tightly the two devices correlate with how close they sit to perfect one-to-one agreement.
- Repeated-measures Bland-Altman analysis: mean difference against mean value, with limits of agreement computed to account for multiple breaths per participant.

**Decision rule.** Equivalence is claimed if and only if the two one-sided tests both reject. The other two are descriptive.

**Structure.** Run within each block and pooled across blocks.

**For simulation.** Requires: the equivalence margin in milliseconds; the within-participant standard deviation of breath-duration differences; the between-participant standard deviation of mean difference; breaths per participant.

## 5.4 H2: Cycle-level detection

**Estimand.** Three quantities: detection agreement, onset timing difference, and count agreement.

**Unit.** Individual breath for the first two; block for the third.

**Tests.**

1. **Detection agreement.** Match each accelerometer onset to a stretch belt onset within a tolerance window. Compute a balanced detection score combining the proportion of accelerometer onsets that correspond to real ones with the proportion of real onsets the accelerometer found. Computed on lag-corrected onsets, with the lag fixed from Block 1 and not refitted.

   The stretch belt is the reference. The tolerance window must exceed the timing precision of the recording itself. Measured accelerometer timestamp jitter is 35 ms standard deviation with a 95th percentile of 74 ms, so a tolerance tighter than about 75 ms is not supportable. Proposed tolerance: 150 ms. **[SIM]**

2. **Onset timing difference.** Median signed difference between matched onsets, computed on **uncorrected** onsets, since this reports the practical offset a user of the accelerometer would face. Reported with its interquartile range.

3. **Count agreement.** Intraclass correlation coefficient on breath counts per block, using a two-way model treating both device and participant as random.

**Decision rule.** All three must pass their thresholds. **[SIM]**

**Note.** Tests 1 and 2 deliberately use different signals. Correcting for lag before matching is necessary or the detection score collapses on signals that track each other well; but reporting timing difference on corrected onsets would be circular, since the lag was fitted to minimise exactly that quantity.

**For simulation.** Requires: expected proportion of onsets matched; distribution of onset timing differences; tolerance window; thresholds for the detection score and the count agreement coefficient.

## 5.5 H3: Rate invariance of timing, rate dependence of depth

**Estimand.** The interaction between imposed rate and device, separately for duration error and depth error.

**Unit.** Trial, nested within participant. Nine Block 3 trials plus approximately 25 Block 4 trials.

**Tests.**

- **(a) Duration.** Mixed-effects model with duration error as outcome, imposed rate as predictor, random intercepts and slopes by participant. The prediction is that rate has no effect. Because this is a claim of no effect, it is tested with equivalence bounds on the rate coefficient, not by failing to reject a null. **[SIM]**
- **(b) Depth.** Same model structure with depth error as outcome. The prediction is a positive relationship: error grows as the period shortens. Tested conventionally.

**Rate range caveat.** Block 3 spans only three levels, 3, 4, and 5 s, so it provides limited leverage on rate dependence. Block 4 spans a wider range, from 2.0 to 6.0 s, but at unevenly sampled levels concentrated near each participant's threshold. Both blocks are pooled, with block included as a covariate, and the effective range of imposed rates achieved is reported.

**For simulation.** Requires: equivalence bounds on the duration by rate coefficient; expected slope of depth error on rate; number of distinct rate levels realised per participant; between-participant variance in slopes.

## 5.6 H4: Accuracy against the pacer

**Estimand.** For each device, the difference between measured breath duration and commanded period. Then the difference between devices in that quantity.

**Unit.** Paced breath. Approximately 136 per participant.

**Tests.**

1. **Per-device accuracy.** Mean signed error and mean absolute error against the commanded period, with participant-level random intercepts. Reported separately for each device.
2. **Between-device equivalence.** Two one-sided tests procedure on the difference in mean absolute error between devices. **[SIM]**

**Note on what this measures.** The difference between measured duration and commanded period contains two components: device measurement error, and the participant's deviation from the pacer. These cannot be separated for a single device. A participant who drifts to 4.4 s when 4.0 s was commanded produces a 400 ms error even on a perfectly accurate device.

The two components do separate in the between-device contrast. Both devices record the same breaths, so the deviation component is identical for each and cancels in the difference. Accordingly:

- **Test 2 is the hypothesis test.** It is a clean comparison of device accuracy.
- **Test 1 is descriptive only**, and is reported as combined device and adherence error, not as device accuracy.

H4 is also logically independent of H1. Two devices can agree closely with each other and both be biased relative to the pacer.

The same quantity carries the opposite role in H8. Here, deviation from the pacer is nuisance to be cancelled. There, it is the outcome of interest.

**For simulation.** Requires: expected mean absolute error per device; equivalence margin on the difference; paced breaths per participant.

## 5.7 H5: Variability agreement

**Estimand.** Agreement between devices on three variability measures.

**Unit.** Free-breathing block, i.e. Blocks 2 and 5. Two per participant, each 120 s, approximately 30 breaths each.

**Measures.** Spread of breath durations relative to their mean; typical size of the change from one breath to the next; predictability of the sequence, using sample entropy.

**Test.** Intraclass correlation coefficient for each measure, two-way random effects, absolute agreement, single measurement. **[SIM]**

**Caveat.** Thirty breaths is a small basis for entropy-type measures, which are known to be unstable at short lengths. The entropy measure is reported with an explicit reliability check and treated as secondary if that check fails.

**Scope note.** RQ5 asks about variability over time generally, while this test uses only the free-breathing blocks. Variability during paced blocks is constrained by the pacer and is therefore not informative about spontaneous variability. This restriction is deliberate.

**For simulation.** Requires: expected agreement coefficient per measure; between-participant variance in each measure; breaths per block.

## 5.8 H6: Within-session stability

**Estimand.** Change in agreement from Block 2 to Block 5, the two free-breathing blocks, and whether that change is predicted by signal quality.

**Unit.** Block, and within-block windows.

**Tests.**

1. **Stability.** Paired comparison of the agreement measure between pre and post blocks, tested for equivalence rather than for difference, since the prediction is no change. **[SIM]**
2. **Moderation.** Mixed-effects model with agreement as outcome and the signal quality index as predictor, over rolling windows across the whole session, controlling for elapsed time. The prediction is that quality carries the effect and elapsed time does not.

**Time base.** Elapsed wall-clock time, not trial index. Trials are participant-initiated, and inter-trial time exceeds task time, so the two are only loosely coupled.

**Quality index tuning.** The index is not recorded during sessions and must be computed offline. Its degradation threshold will be tuned on these data rather than carried over from the pilot recording used to set the live software's values. Tuning procedure to be specified before analysis. **[SIM]**

**For simulation.** Requires: expected pre-to-post change in agreement; equivalence margin on that change; expected relationship between quality index and agreement; number of rolling windows per session.

## 5.9 H7: Downstream equivalence

**Estimand.** Whether substituting one device for the other changes the study's conclusions.

**Unit.** Trial for the classification test; participant for the coefficient test.

**Tests.**

1. **Classification agreement.** Compute the direction-correct classification separately from each device, for every trial. Agreement measured by Cohen's kappa, which corrects for agreement expected by chance. **[SIM]**
2. **Coefficient equivalence.** Fit the same model twice, once with each device supplying the breath-duration predictor. Test whether the two coefficients are equivalent within a margin, using the two one-sided tests procedure on the difference. **[SIM]**

**Note.** This is the decisive hypothesis for the study's practical claim. H1 through H5 can all pass while H7 fails, if the disagreements happen to fall where they matter.

**For simulation.** Requires: expected classification agreement; the base rate of direction-correct classifications; the equivalence margin on coefficients; trials per participant.

## 5.10 H8: Alertness and adherence

**Estimand.** Within-participant relationship between trial-level alertness and trial-level pacer adherence, and whether it differs by device.

**Unit.** Block 4 trial. Approximately 25 per participant.

**Test.** Mixed-effects model with adherence as outcome and alertness as predictor, alertness centred within participant to isolate within-person fluctuation from between-person differences. Random intercepts and slopes by participant. Fitted separately for each device, then tested for equivalence of the alertness coefficient across devices. **[SIM]**

**For simulation.** Requires: expected within-participant alertness effect; within-participant variance in alertness ratings; equivalence margin on the between-device difference; trials per participant.

## 5.11 Exploratory analyses

No corrections for multiple comparisons; reported as exploratory throughout.

**EH1 (serves ERQ2).** Correlations between interoceptive sensibility and each of mean breath duration, breathing variability, and mean pacer adherence. Breath duration and variability are taken from the free-breathing blocks (2 and 5); adherence is taken from the paced blocks (3 and 4), since adherence is undefined without a pacer. Reported with confidence intervals and as directional consistency only, per the limits on ERQ2.

**EH2. Waveform shape.**

To compare shape fairly, the derivative relationship must first be undone. Two routes:

- **(a) Double-integrate the acceleration** to recover a displacement-like waveform, with high-pass filtering to control the drift that integration introduces.
- **(b) Band-pass both signals narrowly** around the breathing fundamental, so that only one frequency component survives and the derivative relationship reduces to a scale factor and a fixed phase shift, both of which normalise away.

Route (b) is not appropriate for this hypothesis. Narrow band-passing discards exactly the harmonic content that constitutes waveform shape, which would make shape agreement near-trivially high. Route (a) is preregistered for EH2. The narrow band-pass remains in use for the timing and rate hypotheses, where it is appropriate.

**Measure.** Magnitude-squared coherence across the respiratory band, a frequency-resolved measure bounded 0 to 1 that asks whether the two signals hold a consistent amplitude ratio and phase relationship at each frequency.

**Caveat on estimation.** Coherence is biased upward when few independent segments are available. At 0.25 Hz, 120 s of free breathing yields very few. Welch segment length and overlap will be specified in advance, and significance assessed against a null built by phase-randomising one signal, rather than against a fixed threshold. Individual Block 3 and Block 4 trials are too short to support coherence at all; for those, shape is assessed instead by correlating time-normalised individual breath cycles between devices.

**Free by-product.** The phase spectrum of the coherence gives a frequency-resolved lag estimate. If the device offset is a true time delay, phase rises linearly with frequency. If it is a fixed mechanical phase shift, phase is flat. Reported either way, as it bears on how lag should be corrected.

**EH3. Calibration model as hidden moderator.**

- Descriptive: how often each of the six candidate models is selected, across participants.
- Test: whether the selected model predicts subsequent agreement between devices, and whether calibration fit predicts agreement independently of which model won.
- Rationale: participants running under different transformations are not running the same measurement, so this checks whether that heterogeneity matters.

**EH4. Directional consistency with prior findings.**

**Unit.** Participant. One observation per person, and the threshold estimate itself carries measurement error, so this is the least precise analysis in the study.

**Reported quantities.**

1. Correlation between detection threshold and interoceptive sensibility, with confidence interval.
2. Correlation between mean confidence and interoceptive sensibility, with confidence interval.
3. The contrast between the two, tested as a difference between dependent correlations sharing a common variable.

**Threshold handling.** Each participant has two thresholds, one per staircase direction. The primary figure uses their mean; the two directions are also reported separately. Participants whose staircases did not converge before the trial cap are retained, and their posterior uncertainty is carried forward as a weight.

**Sensibility scoring.** Total score by default. Subscale correlations are reported uncorrected.

**Directional consistency.** Reported explicitly for each part: for (b), whether the point estimate is positive; for (a), whether the confidence interval falls inside, overlaps, or excludes a region of practical equivalence of plus or minus 0.20. The region is a descriptive reference, not a decision rule.

**Interpretive limits, fixed in advance.** No claim of dissociation will be made from a non-significant threshold correlation. The study is not powered to support a null. No result here is described as reproducing the prior finding, in either direction. This section is descriptive.

## 5.12 Parameters required for the power simulation

Consolidated. Every quantity below must be assigned a plausible value before simulation.

### Design parameters, known

| Parameter | Value |
|---|---|
| Block 3 trials per participant | 9 |
| Block 4 trials per participant | 20 to 60; observed 25 |
| Paced breaths per participant | ~136 |
| Free-breathing breaths per participant | ~60 |
| Total breaths per participant | ~196 |
| Free-breathing duration | 2 blocks of 120 s |
| Distinct imposed rates, Block 3 | 3 |
| Timestamp jitter, standard deviation | 35 ms |

### Effect sizes and margins, to be assumed

| Hypothesis | Parameter |
|---|---|
| H1 | Equivalence margin on breath duration (ms); within- and between-participant variance of the difference |
| H2 | Expected match proportion; onset timing difference distribution; tolerance window; thresholds for detection score and count agreement |
| H3 | Equivalence bounds on duration by rate interaction; expected slope of depth error on rate |
| H4 | Equivalence margin on the between-device difference in mean absolute error; expected magnitude of that difference. The per-device error itself is descriptive and does not drive power |
| H5 | Expected agreement coefficient per variability measure; between-participant variance |
| H6 | Expected pre-to-post change; equivalence margin; quality index effect size |
| H7 | Expected classification agreement; base rate of direction-correct; coefficient equivalence margin |
| H8 | Within-participant alertness effect; alertness rating variance; between-device equivalence margin |

### Notes for the simulation

1. **The binding constraint is H3, H5, H6, H7, or H8.** With the interoception questions moved to exploratory, no analysis operates at the participant level with a single observation per person. Requirements now sit in the range of roughly 40 to 96 participants, driven by the equivalence margins rather than by the design. Sample size should be set by whichever of these requires most.
2. **Equivalence tests dominate.** Six of the eight confirmatory hypotheses rest on equivalence testing, which typically needs larger samples than a difference test at the same margin. Margins should be justified as smallest effects of practical interest, not chosen for convenience.
3. **Block 4 trial count is a random variable**, governed by the stopping rule, not fixed. The simulation should draw it from a plausible distribution rather than fix it at 25, and should reflect that the trial cap truncates the upper tail.
4. **Exploratory analyses are not part of the sample size calculation.** EH1 through EH4 are reported at whatever precision the confirmatory sample affords. EH4 in particular would need well over 200 participants to test confirmatorily, which is out of scope.
5. **Variance parameters come from the internal pilot; effect sizes do not.** Section 1.7 sets out exactly what is extracted and what is blocked. Margins and expected effects must come from prior literature or from stated smallest effects of interest, since no effect-size quantity is observed before the confirmatory analysis.
6. **Assume a non-zero true bias.** Equivalence power peaks when the true difference is zero. The simulation assumes a bias of one quarter of the margin, so that the sample size does not rest on the most favourable case.

---

# 6. Open items

| Item | Status |
|---|---|
| BN-RSPEC datasheet bandwidth | **[NEEDS INPUT]** |
| Sample size and interim re-estimation point | Pending power simulation; see Section 1.7 |
| Pilot participant list | **[NEEDS INPUT]** |
| All equivalence margins and thresholds | Pending power simulation |
| Signal quality index tuning procedure | To be specified before analysis |
| Welch parameters for the coherence analysis | To be specified before analysis |

## Limitations to state

1. **Belt order is not counterbalanced.** The accelerometer is always against the skin and always inside the stretch belt. Any systematic device difference is confounded with placement.
2. **Calibration is brief.** Nineteen seconds, roughly 3,900 samples, to fit four parameters. Extending the fit to the paced blocks would be more stable but would compromise the pacer-accuracy analysis in H4, since the model would then be fitted to predict the very signal it is tested against.
3. **The rate range is narrow.** Block 3 spans 3 to 5 s. Claims about rate dependence rest largely on Block 4, where rates are sampled unevenly around each participant's own threshold.
4. **Condition onset is computed, not measured.** The event code marking it was removed from the software to protect pacer timing. It is reconstructed as trial start plus two baseline breaths, and therefore inherits any jitter in the trial-start code.
5. **Alignment absorbs browser clock wander.** The linear drift correction removes roughly 380 ms of divergence across a session. Analysis of the accelerometer timestamps shows a comparable amount of slow wander in the browser clock, so the correction is largely absorbing browser timing rather than acquisition-hardware error.
