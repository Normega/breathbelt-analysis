# BreathBelt: Comparing an Accelerometer Chest Strap Against a Stretch Respiration Belt

Pre-registration draft. **No item marked [NEEDS INPUT] or [SIM] remains.** Every equivalence margin, decision threshold, sample size parameter and analysis-procedure detail is set and stated; see Sections 5.12 and 5.13 for the consolidated values and Section 6 for the record of what closed and how.

_Power analysis and margins added 2026-08-10. Sampling plan and final margins fixed 2026-08-14: target 75 enrolled, interim variance re-estimation at 40, hard cap 100. H1's margin set at 150 ms, below the 300 ms ceiling derived from H7._

---

# 1. Methods

## 1.1 Design

Within-participant instrument comparison. Every participant wears both respiration sensors simultaneously for a single session, so the two devices record the same breaths under identical conditions. A visual pacer provides a third, independently known reference for breathing rate during the paced blocks.

## 1.2 Participants

Recruited through the university SONA portal, from either the course-credit or the paid pool.

**Eligibility.** Participants had to be comfortable attending to their own breathing and answering questions about mental health. Exclusions at screening: asthma, other chronic respiratory illness, or a cardiovascular condition.

**Pre-session instructions.** Avoid heavy meals, caffeine, and drugs or medication within 30 minutes of the session. No other scheduling constraints.

**Sample size.** **75 participants enrolled.**

Set by the power simulation in Section 5.13. The binding constraint is H6, within-session stability, which reaches 80% power at 75 enrolled and only 70% at 60. Every other confirmatory hypothesis clears 80% at or below 60: H2 at 60, H5 at 40, H3 at 25, and H1, H4, H7 and H8 at 10 or fewer.

The target is stated in **enrolled** participants because not every session yields analysable data. In the internal pilot, 5 of 18 participants produced no matched breaths usable for the breath-level comparison, so 75 enrolled corresponds to roughly 54 analysable. The simulation applies that attrition rather than assuming enrolled and analysable are the same, which would overstate power by about a third.

**The target is provisional by design, and the sampling plan is fixed in advance.** It rests on a single pilot variance component known to about 17%, so a one standard error band on that parameter spans a target of 53 to 103 (Section 5.13). Three numbers are therefore preregistered together:

| | Enrolled N |
|---|---|
| Interim variance re-estimation, once | **40** |
| Target | **75** |
| Hard cap | **100** |

The re-estimation reads nuisance variance only, on the same blinding terms as the initial pilot, and may move the target in either direction up to the cap. It is not an interim look at any hypothesis. Section 1.7 sets out the full procedure.

**Exclusions.** No participant is excluded a priori on the basis of poor performance or poor signal. Participants who adhere poorly to the pacer, or who calibrate poorly, are informative: the question is whether that poor adherence appears similarly on both devices. Exclusion applies only to incomplete data, defined as a session missing usable signal from either device, or missing the trial-level records needed to align them. Flagged but retained cases are described in Section 5.2.

## 1.3 Equipment

**Accelerometer belt.** Polar H10 chest strap, worn directly against the skin. Connects to the study software over Bluetooth Low Energy through a Chrome browser. Provides three-axis acceleration and heart rate.

**Stretch belt.** BioPac system: MP160 acquisition unit with a BN-RSPEC BioNomadix Respiration and ECG wireless system. The transmitter is worn by the participant and the receiver module feeds the MP160. Worn over the participant's clothing.

There is no RSP100C amplifier in this setup and therefore no operator-configurable gain or filter stage. The BioNomadix system's bandwidth is fixed in hardware at **DC to 10 Hz** on the respiration channel, so the only signal conditioning before digitisation is whatever that hardware imposes. This matters for preprocessing: it is the sole anti-alias protection ahead of decimation. Because it is a soft corner rather than a brick wall, decimation is performed with an explicit anti-alias filter rather than by taking every Nth sample. See Section 1.6.

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

**Amplifier.** No configurable amplifier stage exists: the BN-RSPEC BioNomadix system has fixed hardware bandwidth. The respiration channel has a **fixed wideband response of DC to 10 Hz**, specified by the manufacturer to resolve respiratory effort up to 600 breaths per minute as well as near-static conditions such as apnoea. The ECG channel, which this study does not analyse, runs 0.05 to 150 Hz. Both are cited from the manufacturer's published specification rather than measured here.

**Consequence for decimation.** The 10 Hz corner sits below the 12.5 Hz Nyquist frequency of the 25 Hz analysis grid, so the hardware bandwidth is not in itself an aliasing hazard. It is a first-order corner rather than a brick wall, though, so out-of-band energy is attenuated and not removed. Decimation from 2000 Hz is therefore still performed with an explicit anti-alias filter rather than by taking every 80th sample.

**AcqKnowledge template.** The acquisition template defines 17 channels at 2000 Hz: two respiration, two ECG, eight digital trigger lines, one derived trigger channel, two heart rate and two respiration rate calculation channels. The template governs display and derived channels only; the two respiration channels are stored raw in Volts and are not filtered by it.

---

## 1.7 Internal pilot and sample size

At the point this pre-registration was written, 18 participants had completed the full session. No outcome from those sessions has been examined.

Rather than discard them or guess at the variance parameters needed to set a sample size, they are declared an **internal pilot**. Their data are used to estimate nuisance variance only. They remain in the confirmatory sample. Using interim data to re-estimate a nuisance variance, without examining the quantities under test, has negligible effect on the false positive rate, and is a recognised design rather than an informal look.

The guarantee only holds if the restriction is real. It is enforced by script rather than by intention: a single extraction routine computes the permitted quantities, discards everything else before returning, and refuses to write output containing anything outside the list below. Participant-level values are destroyed inside the function that computes them. The pilot sample is fixed in advance and is not extended after output is seen.

### Extracted

Nuisance parameters. None appears in any decision rule in Section 5.

- Between-participant standard deviation of each participant's own mean breath-duration bias
- Within-participant standard deviation of breath-level duration differences
- Between-participant standard deviation of the breath-depth bias
- Between-participant standard deviation of each breathing-variability measure
- Distribution of Block 4 trial counts
- Distribution of **per-device** breath counts
- Distribution of calibration fit, both uncorrected and lag-adjusted
- Distribution of the estimated belt-to-pacer offset
- Distribution of alignment residuals
- Frequency with which each candidate calibration model is selected, and the winning model's margin over the runner-up

Breath count is extracted **per device**, never as a count of matched breaths. The matched count is the numerator of H2's match proportion, which is blocked, so reporting it alongside per-device counts would disclose the blocked quantity by division. An earlier version of the extraction script reported the matched count under the label "breath count"; this was found and corrected before any output was read.

### Blocked

Each is an effect entering a confirmatory decision rule. None is computed, or is computed only inside a function that discards it.

| Blocked quantity | Protects |
|---|---|
| Mean breath-duration bias | H1 |
| Proportion of breaths matched between devices | H2 |
| Count of breaths matched between devices | H2, as the numerator of the above |
| Onset timing difference between devices | H2 |
| Duration or depth error broken down by imposed rate | H3 |
| Any error relative to the pacer | H4 |
| Any agreement coefficient: intraclass, concordance, or kappa | H2, H5, H7 |
| Pre-to-post change in agreement | H6 |
| Any alertness and adherence relationship | H8 |
| Any correlation | H1 to H8, EH1, EH4 |
| Any agreement quantity split by selected calibration model | EH3 |
| Any per-participant value or identifier | All |

Two calls warrant note. Calibration fit and the belt-to-pacer offset are extracted: neither enters a decision rule, both are preprocessing parameters the simulation needs, and the offset distribution is separately required for the check in Section 5.1. Conversely, the proportion of breaths matched between devices is blocked despite being useful, because it is the recall component of H2's test statistic; H2's expected match rate is instead set from a stated smallest effect of interest.

### Sequence

1. Correct the preprocessing pipeline so calibration weights are fitted against the reconstructed pacer. The extraction script refuses to run on files fitted against the stretch belt, since those absorb participant-specific variance and would understate the between-participant standard deviation, yielding an optimistic sample size.
2. Fix the pilot sample and record the participant list here.
3. Run the extraction. Read only its report.
4. Set the equivalence margins, deriving the breath-duration margin from the downstream classification in H7 where possible.
5. Simulate power across a grid of sample sizes and fix a provisional target.
6. Re-estimate the variance **once, at 40 enrolled**, and adjust the target within a **hard cap of 100 enrolled**. Both numbers are fixed here, in advance, and are set out in full below.

### The interim re-estimation, fixed in advance

**Trigger.** Exactly one re-estimation, when the 40th participant has been enrolled. Not repeated, not triggered by any result, and not conditional on anything observed.

**What is recomputed.** The same extraction script, unchanged, over the enlarged sample. Only the nuisance variance components in Section 5.12 are read. Every quantity blocked at the initial estimate stays blocked at the interim: the re-estimation is not an interim look at the hypotheses, and nothing about whether any hypothesis is passing is computed or reported.

**Why 40.** The relative standard error of a standard deviation estimated from *n* observations is approximately 1/sqrt(2(n-1)). At the pilot's 18 that is 17.1%; at 40 it is 11.3%, so a third of the uncertainty is removed. Waiting to 50 gains only a further 1.2 points and costs ten participants of room to react. Forty is where most of the achievable sharpening has been banked while adjustment is still feasible.

**What may change.** The enrolment target only. Margins, decision rules, hypotheses, the analysis plan, and the pilot participant list are all fixed and are **not** revisited. The target may move up or down, bounded above by the cap.

**Why the cap is 100.** If the true CV spread is one standard error above the pilot estimate, H6 needs 103 enrolled for 0.80 power, and stopping at 75 would leave it at 0.665, which is too low for a null result to be interpretable. A cap of 100 holds H6 at 0.794 in that unfavourable case, against 0.897 at the point estimate. A cap at the target would have made the re-estimation unable to act in the only direction that matters.

**If the cap binds.** Should the re-estimate imply a target above 100, recruitment stops at 100 and the shortfall is reported as a limitation, with the realised power stated. The margin is not widened to manufacture power, and no hypothesis is dropped.

### Precision this affords

A variance estimate from 18 participants is usable but not sharp, and in this case one of the two components came back at its boundary.

**The between-participant variance was estimated at exactly zero.** A random-intercept model fitted to the pooled breath-level differences returned a singular fit: the observed spread of participant mean biases is fully explained by within-participant sampling noise. Zero between-participant variance is the *most favourable possible* value for an equivalence design, because it makes the participant-level mean maximally precise and minimises the required sample size. Powering on it would be exactly the optimism this section exists to prevent.

The power analysis therefore uses the **95% profile upper bound of 35.3 ms**, not the point estimate. The within-participant standard deviation, 308.2 ms, is estimated well away from any boundary and is used directly.

A small true between-participant value is substantively plausible rather than suspicious. Breath duration is a timing quantity, and unlike breath depth it has no obvious route by which body shape, posture, or exactly how the strap sits would make it differ systematically between people.

The interim re-estimation at step 6 exists for this reason and matters more than precision in the initial estimate.

### Assumed bias

Power for an equivalence test is highest when the true bias is exactly zero, so assuming zero yields an optimistic sample size. The simulation instead assumes a non-zero bias of one quarter of the equivalence margin. This is fixed in advance.

### Pilot participant list

Fixed before extraction and recorded here. Eighteen participants, being every enrolled participant with an accelerometer file, an acquisition file, Block 3 and Block 4 trial records, and a recorded Block 4 end time:

```
3997   9082   9085   13738  14425  14542  14677  14701  16117
16753  16807  17446  17704  17734  17755  17758  17788  17896
```

Participant 998877 is a test account and is excluded. Six further identifiers appear in acquisition filenames with no accelerometer file (17926, 5965, 14776, 16549, 16711, 9967) and are treated as adjacent-seat occupants with missing or other-study belt data. If any are recovered they join the **confirmatory** sample, not this pilot, and contribute at the interim re-estimation in step 6.

This list is not extended after output has been seen.

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
Calibration selects, per participant, whichever of three candidate transformations best reconstructs the pacer. Different participants therefore run under different transformations. We will describe how often each is selected, and test whether the selected model predicts subsequent agreement between the belts. Not a focal hypothesis, and on the internal pilot the selection looks close to arbitrary; see Section 5.11.

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
| **Accelerometer signal** | Single breathing waveform reconstructed from three-axis acceleration using participant-specific weights. Two filtered copies are carried, not one: a **detection copy** band-passed 0.05 to 0.6 Hz and a **measurement copy** band-passed 0.05 to 2.0 Hz. Extrema are located on the detection copy and then snapped onto the measurement copy before any time or amplitude is read. See Section 5.1. | Accelerometer session file plus calibration weights | Defined |
| **Calibration weights** | Coefficients from a multiple linear regression predicting the reconstructed pacer position from the three acceleration axes band-passed 0.05 to 1.0 Hz, fitted on the Block 1 calibration window only. The narrow 0.10 to 0.4 Hz band offered by the software is **not** used; see Section 5.1. Refitted offline; the weights computed live are used only for the participant's on-screen preview. | Fitted from Block 1, approximately 3,900 samples | Defined |
| **Pacer signal** | Sine wave at the commanded period, anchored to the recorded block or trial onset. Reconstructed analytically. The recorded pacer column is empty in the data files and is not used. | Software trial records | Defined |
| **Common time base** | Both signals resampled to a uniform 25 Hz grid. Accelerometer sample times are reconstructed by back-assigning from each packet timestamp at 4.916 ms intervals, the empirically measured sample period. | Preprocessing | Defined |
| **Belt-to-pacer offset** | Time offset between a device's breathing signal and the reconstructed pacer, estimated by shifting one against the other until correlation peaks. Searched over plus or minus 2000 ms. Deliberately **not** called device lag: it is not a pure transduction delay. See Section 5.1. | Preprocessing | Defined |

## 4.2 Breath-level measures

| Term | Definition | Source | Status |
|---|---|---|---|
| **Breath onset** | Trough in the filtered breathing signal, marking the start of an inhale. Located by a prominence detector on the detection copy, with a minimum prominence of 0.4 in normalised units and a minimum separation of 1 s, then snapped onto the measurement copy. Detected independently in each device's signal by the **same function with the same parameters**, so no per-device tuning can inflate agreement. See Section 5.1. | Both devices | Defined |
| **Breath duration** | Interval between consecutive breath onsets, in milliseconds. Also referred to as breath period. | Both devices | Defined |
| **Breath depth** | Peak-to-trough amplitude of each breath cycle, in each device's native units. Compared after within-participant standardisation, since the units are not commensurable. | Both devices | Defined |
| **Breath count** | Number of detected onsets in a defined window. | Both devices | Defined |
| **Breathing variability** | **Two** measures over each free-breathing block: the coefficient of variation of breath durations, and the root mean square of successive differences. Sample entropy was dropped; see Section 5.7. | Both devices | Defined |
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
| **Signal quality index** | Explained variance ratio. Over a rolling 15 s window of the band-passed three-axis acceleration, the proportion of total movement variance that lies along the calibrated breathing direction. Bounded 0 to 1. Falls when the participant shifts posture, the strap slips, or non-respiratory movement intrudes. Not recorded during sessions; computed offline from raw acceleration and the calibration weights. Used **continuously** in H6 test 2; flagged at a fixed anchor of **0.50** in Section 5.2. No threshold is tuned; see Section 5.8. | Computed offline | Defined |
| **Selected calibration model** | Which of **three** candidate transformations won calibration for each participant: multiple regression with or without a smoothing step, or principal component analysis, all on the 0.05 to 1.0 Hz band. The three narrow-band variants were dropped; see Section 5.1. | Session record | Defined |
| **Model margin** | Fit of the winning calibration model minus fit of the runner-up. Selection is only interpretable where this is meaningfully above zero. | Refit | Defined |
| **Calibration fit** | Correlation between the reconstructed accelerometer signal and the pacer during Block 1. Reported both uncorrected and after removing the estimated belt-to-pacer offset, because the two are mechanically confounded: a perfect model still scores only cos(2 pi offset / period) against an unshifted pacer. | Session record and refit | Defined |
| **Alignment residual** | Per-trial discrepancy between the two devices' clocks after linear correction. Diagnostic. | Preprocessing | Defined |

## 4.6 Expected observation counts

From the internal pilot of 18 participants, for design purposes. Nominal counts are what the design delivers; **usable** counts are what survives detection and between-device matching, and they are what the power simulation uses.

| Unit | Count per participant |
|---|---|
| Block 3 trials | 9, fixed |
| Block 4 trials | median 25, range 24 to 35 observed; 20 to 60 by stopping rule |
| Paced breaths, nominal | Approximately 136 |
| Free-breathing breaths, nominal | Approximately 60, across both blocks |
| Total breaths, nominal | Approximately 196 |
| Free-breathing breaths detected, per device | median 59, range 48 to 78 |
| **Matched breaths usable for the breath-level comparison** | **Approximately 42** |
| Free-breathing signal | 240 s |
| Total streaming time | Approximately 20 minutes |

**The gap between nominal and usable is large and is not an error.** A breath contributes to the duration comparison only when both devices resolve both of its ends, which is the rule H1 requires and is stated in Section 5.3. Roughly 42 of about 196 nominal breaths survive that rule.

**Participant-level attrition.** In the pilot, 13 of 18 participants yielded any usable matched breaths at all; the remaining 5 yielded none. The simulation applies that yield, so a target stated in enrolled participants is converted to analysable participants before power is computed. The five contributing nothing coincide in number with the five flagged for low calibration fit, which is consistent with poor calibration propagating into failed matching, but this has not been verified participant by participant because that would require a per-participant disclosure.

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
   - The same convention applies to every other filter in the chain: the 0.6 Hz detection band and the 2.0 Hz measurement band at step 7, and the 0.6 Hz smooth used by one of the three calibration candidates at step 5.

   This differs from the live software, which applies 2nd-order biquad sections under the same forwards-and-backwards scheme and is therefore effectively 4th order. The offline specification above is authoritative; the live filters exist only to drive the participant's on-screen preview.

   **Edge handling.** Every zero-phase filter pass is preceded by odd-reflection padding of 15 seconds at each end, and the padding is discarded afterwards. This is not cosmetic. The calibration window is 16 s while the 0.05 Hz high-pass corner has a 20 s period, so an unpadded filter spends the entire window settling: in synthetic testing an unpadded pass recovered an injected 320 ms offset as 160 ms and failed to recover the breathing direction at all. The live software pads for the same reason. `signal::filtfilt` in R does not pad by default, so the padding is applied explicitly.
5. **Calibrate.** Fit multiple linear regression weights predicting the reconstructed pacer from the three band-passed axes, using the Block 1 window only.

   **Candidate models: three, not six.** The software offers each transformation on a wide 0.05 to 1.0 Hz band and on a narrow 0.10 to 0.4 Hz band. **The narrow band is not used offline.** A 0.4 Hz cutoff sits barely above the respiratory fundamental, so it symmetrises every breath and biases extremum timing, which is the same defect described at step 7 below. The consequence was measured on the designated debugging participant, whose winning model under the old rule was the narrow-band variant: its median duty cycle read between 0.48 and 0.55 in every block, pinned at 0.50 regardless of true morphology, while the stretch belt on the same breaths read 0.43 to 0.47. A reconstruction that cannot express inhale-exhale asymmetry cannot support H2's onset timing, H3's depth-by-rate interaction, or EH2's waveform shape.

   Dropping it also makes participants comparable: under the old rule a narrow-band participant and a wide-band participant were not running the same measurement. The candidate set is therefore multiple regression, multiple regression with a 0.6 Hz smooth, and principal component analysis, all on 0.05 to 1.0 Hz.

6. **Correct for the belt-to-pacer offset.** Estimate it by cross-correlation over plus or minus 2000 ms, per participant, on the Block 1 window. Apply the same value throughout the session.
7. **Detect breath onsets.** Independently in each device's signal, using the same function with the same parameters. Per-device tuning is not permitted: it would inflate exactly the agreement H2 exists to test.

   **Two filtered copies, not one.** Extrema are located on a **detection copy** band-passed 0.05 to 0.6 Hz, then snapped onto a **measurement copy** band-passed 0.05 to 2.0 Hz before any time or amplitude is read from them.

   Detecting and measuring on a single narrow band symmetrises the waveform and pushes extrema late. On synthetic breaths with exact ground truth, the worst single-device trough timing error over commanded periods of 2 to 6 s was 293 ms with a 0.6 Hz measurement band against 199 ms at 2.0 Hz. The 2.0 Hz cutoff also sits at the knee of the duty-cycle bias curve, which matters for EH2.

   **Detector.** Local maxima filtered by prominence, minimum prominence 0.4 in normalised units, minimum separation 1 s, with extrema then refined onto the measurement copy within a 0.5 s window. The prominence threshold was fixed by inspecting what it rejects on the designated debugging participant: the accelerometer's count of implausible inter-onset intervals falls 26, 20, 17, 12, 10 across thresholds of 0.10 to 0.40 and then plateaus at 9 through 0.80, so 0.4 sits at the knee. Below 0.3 the detector manufactures short cycles out of noise. The stretch belt is clean at every threshold, so the accelerometer sets the constraint.

   Onsets are detected **once on the continuous session** and then assigned to blocks by time, rather than by filtering each block separately. A Block 3 or Block 4 trial is only about 16 s long while the 0.05 Hz corner has a 20 s period, so filtering trial segments individually cannot settle.

   **This detector is shared.** The same function produces the onsets used for the internal pilot variance estimation and for every confirmatory analysis. If they differed, the variance components would not describe the signal the confirmatory analysis sees.

8. **Compute the signal quality index** in rolling 15 s windows.

**Circularity control.** Calibration weights are fitted against the pacer, never against the stretch belt. This keeps the stretch belt out of the accelerometer's construction, so agreement between the two devices is not inflated by shared fitting. A version fitted against the stretch belt on the pre free-breathing block will be reported as a sensitivity analysis and interpreted as an upper bound only.

**Lag applied consistently.** The software computes some trial-level agreement measures with lag correction and others without. All measures are recomputed offline with lag correction applied uniformly, so that no comparison contrasts a corrected quantity against an uncorrected one.

**What the offset is, and is not.** This quantity was previously called device lag, on the reasoning that it reflects signal transduction and processing and should therefore be positive. That reasoning is wrong and the name has been changed.

The offset is measured between a device's breathing signal and the pacer, so it contains at least three components:

- device transduction and filter delay, positive
- **participant anticipation of the pacer, negative.** Anticipating a predictable rhythmic cue is the standard finding in sensorimotor synchronisation, where negative mean asynchrony of tens to a couple of hundred milliseconds is typical rather than exceptional
- residual error in the reconstructed pacer anchor, either sign

A negative value is therefore an expected result, not an anomaly. No positivity expectation is preregistered. Offsets are reported as a distribution, and values beyond plus or minus 1000 ms are flagged for inspection as implausible in either direction.

True device lag is not identifiable from this quantity. It would require a between-device comparison, which is reserved for the confirmatory analysis.

### A block-dependent between-device offset, predicted in advance

The two devices do not measure the same physical quantity. The stretch belt measures displacement; the accelerometer measures acceleration, which amplifies harmonic *n* of the breath by *n* squared. For a **symmetric** breath that changes nothing about where the trough falls. For an **asymmetric** breath it reshapes the waveform and moves the trough.

This has a consequence the design makes sharp, and it is preregistered here as a prediction rather than discovered later:

- **The pacer is symmetric.** Its radius follows (1 minus cosine) over 2, so a participant tracking it breathes with an inspiratory fraction near 0.50. In the paced blocks the between-device onset offset from this mechanism is therefore near zero.
- **Spontaneous breathing is not symmetric.** Its inspiratory fraction runs nearer 0.43, and at that asymmetry the same mechanism produces a systematic between-device onset offset of roughly 135 to 225 ms.

On synthetic breaths with exact ground truth, the differential trough bias between an acceleration-derived and a displacement-derived signal was under 1 ms at an inspiratory fraction of 0.50 and between 135 and 250 ms at 0.35 to 0.45, at every measurement band tested. The band barely moves it; the asymmetry drives it entirely.

**The Block 1 correction cannot remove it.** The belt-to-pacer offset is estimated on the calibration block, which is paced and therefore symmetric, where this component is zero. Applied to the free-breathing blocks it under-corrects by the full amount. Estimating a separate free-breathing correction is not available either: with no pacer there, it could only be fitted between the two devices, which is H2's estimand and is blocked.

H2's tolerance is therefore block-specific, and Section 5.4 states it. These magnitudes come from a synthetic model of asymmetry rather than a measurement of this study's data, and the inspiratory fraction is taken from an external archive of stretch-belt recordings, so the mechanism and its direction are firm while the magnitudes are order-of-magnitude.

### Decomposing the belt-to-pacer offset

The offset is modelled rather than treated as a single per-participant number, because its sources differ in how they vary and only some of them are nuisance.

**Unit.** Individual paced breath, in Blocks 3 and 4, i.e. four breaths per trial across roughly 34 trials. Approximately 136 per participant, and about 2,400 across the pilot sample. Free-breathing blocks are excluded because they have no pacer.

**Why per breath rather than per participant.** The Block 1 estimate inherits the uncertainty in the reconstructed pacer anchor, roughly plus or minus 88 ms of packet quantisation, and that error is constant within a participant. It is therefore exactly confounded with the participant-level term and inflates the between-participant variance. Trial pacers do not have this problem: each trial is anchored to a **hardware trigger timestamped at 2000 Hz**, so the pacer onset is known to well under a millisecond.

**Definitions.** `offset` is the signed difference between a detected breath onset and the corresponding commanded pacer onset, positive when the breath trails the pacer.

`breath_index` is the breath's position **within its own trial**, 1 to 4, not a running count across the session. This matters: every trial is re-anchored to its own hardware trigger, so pacer overshoot accumulates within a trial and resets at the next one. A cumulative index would model a session-long drift that does not exist and would absorb the overshoot into the wrong term.

`rig` is a two-level factor, left or right testing computer, taken from the recorded trigger codes rather than from the session record.

**Model.**

```
offset ~ 1 + breath_index + rig
         + (1 + breath_index | participant)
         + (1 | participant:trial)
```

| Term | Interprets as | Status |
|---|---|---|
| intercept | display and transduction latency | **blocked**, see below |
| `breath_index` | per-breath pacer overshoot | extracted |
| `rig` | per-computer display latency | extracted |
| participant intercept | individual anticipation or rushing | extracted, as a variance |
| participant slope | whether overshoot differs by person | extracted, as a variance |
| `participant:trial` | trial-to-trial variation | extracted, as a variance |

**Disclosure.** Only the variance components, the `breath_index` slope, and the `rig` contrast are extracted. **The fixed intercept is blocked**: it is a mean signed error relative to the pacer, which is close enough to H4's estimand that it is treated as an effect rather than a nuisance. The variances and slopes carry everything the power simulation needs without it.

Only the accelerometer's offset is decomposed. A parallel decomposition for the stretch belt, and any comparison of transduction terms between the two devices, is H4's between-device test and is not computed before the confirmatory analysis.

**Expected structure, stated in advance.** The `breath_index` slope should be positive and close to constant across participants, because the pacer overshoot arises from software timing rather than from the participant: it measures 83 to 86 ms per breath across the pilot sample. A materially non-zero participant random slope would indicate that this mechanism has been misunderstood, and is preregistered as a check on it. The participant intercept variance is expected to dominate.

**Precision.** The `rig` term is weakly estimated: only two participants ran on the left computer. It is reported with its interval and not relied upon.

**Dependency.** This model requires breath-onset detection, so it follows the onset detector specified for H2 and uses that same detector.

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

**Unit.** Individual breath, matched between devices. Approximately 42 usable per participant, not the roughly 196 nominal; see Section 4.6 and the matching rule below.

**Matching rule.** Onsets are matched between devices nearest-first, greedily, within a **500 ms tolerance**, on lag-corrected onsets. A breath contributes a duration only when **both devices resolve both of its ends**: the opening and closing onsets are each a matched pair and each is adjacent in its own device's onset sequence.

Two parts of that need justifying.

*Why 500 ms, and why it is a single value where H2's is block-specific.* The two windows do different jobs. H2's tolerance is a **test parameter**: detection agreement is the hypothesis, so the window is pinned to what the recording can support and is widened in the free-breathing blocks only to absorb the offset Section 5.1 predicts there. H1's window is **bookkeeping**: it answers only "is this the same breath", so one value serves every block and no result depends on it. A window as tight as H2's paced value of 150 ms would admit only breaths that already agree in timing to within 150 ms, which conditions H1's duration comparison on good timing agreement and biases the within-participant standard deviation downward. 500 ms also comfortably exceeds the free-breathing offset, so H1's matching does not degrade between blocks the way H2's detection score is expected to. 500 ms cannot create false pairs: a window only mismatches if it reaches past the midpoint between adjacent breaths, and the fastest breathing in the design is Block 4's 2.0 s floor, where the half-period is 1000 ms. If a device misses a breath entirely, the neighbouring onset is a full period away and falls outside the window, so a miss stays a miss.

*Why both ends must be resolved.* The permissive alternative, taking each device's own next onset without requiring it to be matched, admits **detection misses as though they were duration disagreements**: a device that misses the closing onset reports a duration spanning two breaths, contributing an error of a full breath period. Measured on the pilot, the within-participant standard deviation of the difference rose from 315 ms under the strict rule to 1460 ms under the permissive one, against a breath period near 4000 ms. That is a detection statistic wearing a duration statistic's clothes, and detection is H2's question. The cost of the strict rule is the reduced usable count in Section 4.6, and it is reported rather than hidden.

**Primary test.** Two one-sided tests procedure. Two separate one-sided tests ask whether the mean difference is meaningfully greater than the lower margin, and whether it is meaningfully less than the upper margin. Rejecting both supports equivalence.

**Margin: 150 ms.** Set against a derived ceiling of 300 ms, and deliberately tighter than it.

The derivation in Section 5.13 answers the question "at what between-device duration bias do the study's downstream conclusions start to change", and returns 300 ms. That is a **ceiling on what may be tolerated**, not a statement of what should be claimed. The design supports far more precision than the ceiling requires: roughly 27 ms at 0.80 power at the target sample size. Preregistering the ceiling would have claimed much less than the study can support, while preregistering the floor would risk failing for reasons unrelated to the instrument.

**150 ms** sits between them, at half the derived ceiling and about 5.5 times the 0.80-power floor. Halving the margin costs nothing in sample size, because the target is set by H6 and H1 remains saturated at every N considered. Fixed in advance, 2026-08-14.

**Supporting descriptives**, reported but not part of the decision rule:

- Lin's concordance correlation coefficient, which combines how tightly the two devices correlate with how close they sit to perfect one-to-one agreement.
- Repeated-measures Bland-Altman analysis: mean difference against mean value, with limits of agreement computed to account for multiple breaths per participant.

**Decision rule.** Equivalence is claimed if and only if the two one-sided tests both reject. The other two are descriptive.

**Structure.** Run within each block and pooled across blocks.

**Parameters used.** Margin 150 ms; within-participant standard deviation 308.2 ms; between-participant standard deviation 35.3 ms (95% upper bound); 42 usable breaths per participant. Power is 0.99 at 10 enrolled and 1.00 from 20 upward, so H1 does not constrain the design even at the tightened margin.

## 5.4 H2: Cycle-level detection

**Estimand.** Three quantities: detection agreement, onset timing difference, and count agreement.

**Unit.** Individual breath for the first two; block for the third.

**Tests.**

1. **Detection agreement.** Match each accelerometer onset to a stretch belt onset within a tolerance window. Compute a balanced detection score combining the proportion of accelerometer onsets that correspond to real ones with the proportion of real onsets the accelerometer found. Computed on lag-corrected onsets, with the lag fixed from Block 1 and not refitted.

   The stretch belt is the reference. The tolerance window must exceed the timing precision of the recording itself. Measured accelerometer timestamp jitter is 35 ms standard deviation with a 95th percentile of 74 ms, so a tolerance tighter than about 75 ms is not supportable.

   **The tolerance is block-specific, and this is fixed in advance.**

   | Blocks | Tolerance |
   |---|---|
   | 3 and 4, paced | **150 ms** |
   | 2 and 5, free breathing | **400 ms** |

   The paced value is set by timestamp jitter alone, as above. The free-breathing value additionally absorbs the systematic between-device offset that Section 5.1 predicts for asymmetric breathing, roughly 135 to 225 ms, which the Block 1 correction cannot remove because Block 1 is paced and therefore symmetric.

   A single tolerance would be wrong in one direction or the other. At 150 ms throughout, the free-breathing detection score would fall for a reason that is not device disagreement at all, and H2 would fail on a filter-and-physiology interaction rather than on the belts. At 400 ms throughout, the paced test would be loosened far beyond what its own timing precision requires. Both tolerances and the reasoning above are preregistered; the block difference in detection score is reported and interpreted in light of it.

2. **Onset timing difference.** Median signed difference between matched onsets, computed on **uncorrected** onsets, since this reports the practical offset a user of the accelerometer would face. Reported with its interquartile range.

3. **Count agreement.** Intraclass correlation coefficient on breath counts per block, using a two-way model treating both device and participant as random.

**Decision rule.** All three must pass:

1. Detection score lower 95% bound above **0.85**, against a stated smallest effect of interest of 0.90.
2. Median onset timing difference within the block's tolerance.
3. Count agreement coefficient lower 95% bound above **0.75**.

**Note.** Tests 1 and 2 deliberately use different signals. Correcting for lag before matching is necessary or the detection score collapses on signals that track each other well; but reporting timing difference on corrected onsets would be circular, since the lag was fitted to minimise exactly that quantity.

**Parameters used.** The expected match proportion is a **stated** smallest effect of interest, not a pilot estimate: the match proportion is blocked by Section 1.7, so no observed value exists. The simulated curve therefore shows how precision grows with sample size at that assumed effect; it is not a prediction of the effect. H2 reaches 0.80 power at 60 enrolled and 0.93 at 75.

## 5.5 H3: Rate invariance of timing, rate dependence of depth

**Estimand.** The interaction between imposed rate and device, separately for duration error and depth error.

**Unit.** Trial, nested within participant. Nine Block 3 trials plus approximately 25 Block 4 trials.

**Tests.**

- **(a) Duration.** Mixed-effects model with duration error as outcome, imposed rate as predictor, random intercepts and slopes by participant. The prediction is that rate has no effect. Because this is a claim of no effect, it is tested with equivalence bounds on the rate coefficient, not by failing to reject a null. **Equivalence bound: 0.05**, in milliseconds of between-device duration error per millisecond of imposed period change. A 1000 ms change in commanded period may move the between-device duration error by at most 50 ms. This is a stated smallest effect of interest.
- **(b) Depth.** Same model structure with depth error as outcome. The prediction is a positive relationship: error grows as the period shortens. Tested conventionally.

**Rate range caveat.** Block 3 spans only three levels, 3, 4, and 5 s, so it provides limited leverage on rate dependence. Block 4 spans a wider range, from 2.0 to 6.0 s, but at unevenly sampled levels concentrated near each participant's threshold. Both blocks are pooled, with block included as a covariate, and the effective range of imposed rates achieved is reported.

**Parameters used.** Equivalence bound 0.05 on the duration-by-rate coefficient. H3(a) reaches 0.80 power at 25 enrolled and 0.995 at 60, so it does not constrain the design.

## 5.6 H4: Accuracy against the pacer

**Estimand.** For each device, the difference between measured breath duration and commanded period. Then the difference between devices in that quantity.

**Unit.** Paced breath. Approximately 136 per participant.

**Tests.**

1. **Per-device accuracy.** Mean signed error and mean absolute error against the commanded period, with participant-level random intercepts. Reported separately for each device.
2. **Between-device equivalence.** Two one-sided tests procedure on the difference in mean absolute error between devices. **Margin: 150 ms**, the same as H1. The quantity is in the same units and on the same physical scale, so the same threshold of practical interest applies. Stated, not separately derived.

**Note on what this measures.** The difference between measured duration and commanded period contains two components: device measurement error, and the participant's deviation from the pacer. These cannot be separated for a single device. A participant who drifts to 4.4 s when 4.0 s was commanded produces a 400 ms error even on a perfectly accurate device.

The two components do separate in the between-device contrast. Both devices record the same breaths, so the deviation component is identical for each and cancels in the difference. Accordingly:

- **Test 2 is the hypothesis test.** It is a clean comparison of device accuracy.
- **Test 1 is descriptive only**, and is reported as combined device and adherence error, not as device accuracy.

H4 is also logically independent of H1. Two devices can agree closely with each other and both be biased relative to the pacer.

The same quantity carries the opposite role in H8. Here, deviation from the pacer is nuisance to be cancelled. There, it is the outcome of interest.

**Parameters used.** Margin 150 ms. Power is 0.99 at 10 enrolled and 1.00 from 20 upward, so H4 does not constrain the design. Note that the simulation uses H1's participant-level standard deviation for this test. The estimands differ, and a dedicated variance for the between-device difference in mean absolute error is not available without disclosing an error relative to the pacer, which is blocked. Because H4 is saturated at every sample size, this simplification does not affect the target, but the power figure below should be read as H1's precision applied to H4's margin rather than as an independent estimate of H4's own precision.

## 5.7 H5: Variability agreement

**Estimand.** Agreement between devices on **two** variability measures.

**Unit.** Free-breathing block, i.e. Blocks 2 and 5. Two per participant, each 120 s, approximately 30 breaths each.

**Measures.** Coefficient of variation of breath durations, and the root mean square of successive differences.

**Sample entropy is dropped.** The draft previously named it as a third measure while conceding that thirty breaths is a small basis for an entropy-type statistic and that it would be demoted if a reliability check failed. Preregistering a measure that the same paragraph half-disowns is worse than not preregistering it. Two measures, both stable at this breath count and both computed by validated code, replace three. H5's decision rule is correspondingly two coefficients rather than three.

**Test.** Intraclass correlation coefficient for each measure, two-way random effects, absolute agreement, single measurement.

**Decision rule.** For each measure, the lower 95% bound of the coefficient exceeds **0.75**. This is a stated smallest effect of interest: no observed agreement coefficient is available, because every agreement coefficient is blocked by Section 1.7.

**Scope note.** RQ5 asks about variability over time generally, while this test uses only the free-breathing blocks. Variability during paced blocks is constrained by the pacer and is therefore not informative about spontaneous variability. This restriction is deliberate.

**Parameters used.** Target 0.75; between-participant standard deviation of the coefficient of variation 0.108 and of the root mean square of successive differences 839.5 ms, both from the internal pilot. As with H2, the expected agreement level is stated rather than observed, so the curve shows how precision grows with sample size at that assumed effect. H5 reaches 0.80 power at 40 enrolled and 0.96 at 60.

## 5.8 H6: Within-session stability

**Estimand.** Change in agreement from Block 2 to Block 5, the two free-breathing blocks, and whether that change is predicted by signal quality.

**Unit.** Block, and within-block windows.

**Tests.**

1. **Stability.** Paired comparison of the agreement measure between pre and post blocks, tested for equivalence rather than for difference, since the prediction is no change. **Margin: 0.05 on the coefficient of variation scale.** Against a typical coefficient of variation near 0.15, that is a third of the measure: the smallest pre-to-post change that would count as the belts degrading with wear. Stated smallest effect of interest.
2. **Moderation.** Mixed-effects model with agreement as outcome and the signal quality index as predictor, over rolling windows across the whole session, controlling for elapsed time. The prediction is that quality carries the effect and elapsed time does not.

**Time base.** Elapsed wall-clock time, not trial index. Trials are participant-initiated, and inter-trial time exceeds task time, so the two are only loosely coupled.

**Quality index: no threshold enters the confirmatory test.** Earlier drafts deferred a "tuning procedure" for the index's degradation threshold. Specifying one turned out to be the wrong problem to solve, because tuning a cut point on the same data that H6 is tested on invites exactly the leak this design exists to prevent: a threshold chosen to maximise the moderation effect would manufacture the result H6 test 2 predicts. Three commitments replace it.

**1. The moderation test uses the index continuously.** In H6 test 2 the signal quality index enters as a continuous predictor, standardised within participant, with no dichotomisation at any value. No threshold is required for the hypothesis, so none is tuned. Continuous use is also the more powerful form, so nothing is given up.

**2. The flag in Section 5.2 uses a fixed, interpretable anchor: 0.50.** The index is an explained-variance ratio, so 0.50 is the point below which less than half of the movement variance in the window lies along the calibrated breathing direction. That is a meaning, not a percentile, and it requires no reference to the data. Windows below it are flagged and reported. Flagging never excludes, per Section 5.2.

**3. Whether 0.50 sits sensibly in this data's distribution is checked, and reported, but cannot move it.** The distribution of window-level index values will be reported alongside the flag rate. The index is computed from raw acceleration and the calibration weights only, so it is a single-device signal property and involves no between-device quantity. If 0.50 turns out to fall in an uninformative part of the distribution, that is reported as a limitation of the flag. **The anchor is not moved after the distribution is seen**, and no alternative threshold is substituted.

This closes the last **[SIM]** in the document.

**H6 is the binding constraint on sample size.** It reaches 0.80 power at **75 enrolled** and only 0.70 at 60. Every other confirmatory hypothesis clears 0.80 at or below 60. The target in Section 1.2 is set by this test.

The reason is structural rather than incidental. H6 has the fewest observations per participant of any confirmatory hypothesis: two free-breathing blocks, so exactly one pre-to-post difference per person. Where H1 averages roughly 42 breaths per participant before comparing across people, H6 has a single number each, so its precision comes almost entirely from the number of participants.

**Parameters used.** Margin 0.05; between-participant standard deviation of the coefficient of variation 0.108, from the internal pilot; assumed true change one quarter of the margin. Below about 20 enrolled the power is zero rather than merely low, because the margin is then narrower than the confidence interval and no sample can bound it at all.

## 5.9 H7: Downstream equivalence

**Estimand.** Whether substituting one device for the other changes the study's conclusions.

**Unit.** Trial for the classification test; participant for the coefficient test.

**Tests.**

1. **Classification agreement.** Compute the direction-correct classification separately from each device, for every trial where the cued change is non-zero.

   **The decision statistic is Gwet's AC1, not Cohen's kappa.** Decision rule: AC1 lower 95% bound above **0.80**. Kappa and raw percent agreement are reported alongside as descriptives, without thresholds.

   Kappa was the original rule and is **degenerate for this design**. The direction-correct base rate sits near 0.95, because participants are following a visible pacer and most trials classify correctly. At that prevalence, chance agreement is almost as high as observed agreement, so kappa collapses: in simulation it reads about +0.19 at **zero** injected between-device bias, already far below any usable floor, and it is **non-monotonic** in the bias it is supposed to track, reading +0.19, +0.04, +0.06 and +0.14 at biases of 0, 100, 200 and 400 ms. A rule that fails when the devices agree perfectly cannot discriminate device quality.

   This possibility was anticipated. Percent agreement and AC1 were already preregistered as companion descriptives specifically so that a prevalence artefact would be diagnosable rather than fatal. It was diagnosed, and AC1 is promoted to the rule. Both companions behave monotonically: across the same bias range percent agreement runs 0.914, 0.905, 0.882, 0.809 and AC1 runs 0.904, 0.893, 0.864, 0.759.

2. **Coefficient equivalence.** Fit the same model twice, once with each device supplying the breath-duration predictor. Test whether the two coefficients are equivalent within a margin, using the two one-sided tests procedure on the difference. **Margin: 75 ms**, half of H1's. A coefficient shift smaller than that cannot move a conclusion if the durations themselves are equivalent to within 150 ms. Stated smallest effect of interest, and it tracks H1: when H1's margin was tightened from the 300 ms ceiling to 150 ms, this followed to 75 ms rather than being re-chosen.

3. **Device-specific missingness.** The rate at which one device yields a classification and the other does not is reported **as part of the decision, not as a footnote**.

   This matters more than it appears. The classification is undefined when the breaths it needs were not detected, and in a two-device comparison the accelerometer may fail where the stretch belt succeeds. Any agreement coefficient needs complete pairs, so those trials drop silently out of the very analysis meant to detect them. **A device that yields no answer is not equivalent to one that yields the right answer.** Note also that averaging with missing values removed lets a pair mean be computed from a single detected breath, so partial detection degrades quietly rather than becoming missing. Both the missingness rate and the rate of single-breath pair means are reported.

**Note.** This is the decisive hypothesis for the study's practical claim. H1 through H5 can all pass while H7 fails, if the disagreements happen to fall where they matter.

**Trial count is smaller than it looks.** Catch trials carry no cued change and therefore never receive a classification. Trials arrive in shuffled blocks of five with one catch trial, so H7 rests on roughly **four fifths** of Block 4, not all of it. In Block 3 the unchanged condition is excluded for the same reason, leaving 6 of 9 trials. Simulating 25 Block 4 trials per participant would overstate H7's information by about 20%, and the simulation excludes them explicitly.

**Base rate is assumed, not observed.** Section 5.12 note 5 forbids taking an effect size from the internal pilot, and the prior study's data is not available to this project, only its scripts. The base rate is therefore derived from the design and from the breath-duration noise the pilot did license, with participant adherence to the pacer assumed at 0.80. The derivation and its sensitivity are in Section 5.13.

**Parameters used.** AC1 floor 0.80; coefficient margin 75 ms. Power is 0.98 at 10 enrolled and 1.00 from 20 upward, so H7 does not constrain the design.

## 5.10 H8: Alertness and adherence

**Estimand.** Within-participant relationship between trial-level alertness and trial-level pacer adherence, and whether it differs by device.

**Unit.** Block 4 trial. Approximately 25 per participant.

**Test.** Mixed-effects model with adherence as outcome and alertness as predictor, alertness centred within participant to isolate within-person fluctuation from between-person differences. Random intercepts and slopes by participant. Fitted separately for each device, then tested for equivalence of the alertness coefficient across devices. **Margin: 75 ms** of adherence per standard deviation of alertness, half of H1's, on the same reasoning as H7's coefficient test. Stated smallest effect of interest.

**Note on what is and is not tested.** The equivalence test concerns the **between-device difference** in the alertness coefficient. Whether alertness predicts adherence at all is reported per device but is not the confirmatory claim, since a relationship that is absent on both devices is still equivalent across them.

**Parameters used.** Margin 75 ms; Block 4 trial count drawn per participant rather than fixed. H8 reaches 0.80 power at 15 enrolled and 1.00 from 40 upward, so it does not constrain the design. H8 is the one test the margin tightening moved materially: at the former 150 ms margin it cleared 0.80 by 10 enrolled, and at 75 ms it needs 15. That is still far below the target.

## 5.11 Exploratory analyses

No corrections for multiple comparisons; reported as exploratory throughout.

**EH1 (serves ERQ2).** Correlations between interoceptive sensibility and each of mean breath duration, breathing variability, and mean pacer adherence. Breath duration and variability are taken from the free-breathing blocks (2 and 5); adherence is taken from the paced blocks (3 and 4), since adherence is undefined without a pacer. Reported with confidence intervals and as directional consistency only, per the limits on ERQ2.

**EH2. Waveform shape.**

To compare shape fairly, the derivative relationship must first be undone. Two routes:

- **(a) Double-integrate the acceleration** to recover a displacement-like waveform, with high-pass filtering to control the drift that integration introduces.
- **(b) Band-pass both signals narrowly** around the breathing fundamental, so that only one frequency component survives and the derivative relationship reduces to a scale factor and a fixed phase shift, both of which normalise away.

Route (b) is not appropriate for this hypothesis. Narrow band-passing discards exactly the harmonic content that constitutes waveform shape, which would make shape agreement near-trivially high. Route (a) is preregistered for EH2. The narrow band-pass remains in use for the timing and rate hypotheses, where it is appropriate.

**Measure.** Magnitude-squared coherence across the respiratory band, a frequency-resolved measure bounded 0 to 1 that asks whether the two signals hold a consistent amplitude ratio and phase relationship at each frequency.

**Estimation parameters, fixed in advance.** Coherence is biased upward when few independent segments are available: with *K* segments, the expected coherence between two unrelated signals is approximately 1/*K*, not zero. At 0.25 Hz, 120 s of free breathing yields few enough segments that this bias is the dominant estimation concern, so the parameters are chosen to trade frequency resolution against it explicitly.

| Parameter | Value | Consequence |
|---|---|---|
| Sampling rate | 25 Hz | 120 s block gives 3,000 samples |
| Segment length | 512 samples, 20.5 s | Frequency resolution 0.049 Hz |
| Overlap | 50% | About 10 segments per block |
| Window | Hann | Standard sidelobe control |

At a respiratory fundamental near 0.25 Hz this places roughly five bins below the fundamental, which is enough to separate it from the 0.05 Hz high-pass corner, while ten segments hold the null coherence near 0.1 rather than the 0.2 that a 40 s segment would give.

Longer segments were rejected: 1,024 samples would sharpen resolution to 0.024 Hz but leave only about five segments, doubling the upward bias in the quantity being interpreted. Shorter segments were rejected in the other direction: 256 samples gives 0.098 Hz resolution, which is too coarse to separate the fundamental from the filter corner.

**Significance is assessed against a phase-randomised null, not against a fixed threshold.** One signal is phase-randomised with its amplitude spectrum preserved, the coherence is recomputed, and this is repeated 1,000 times to build a per-frequency null distribution. The 95th percentile of that distribution is the reference. This absorbs the segment-count bias directly, because the surrogate coherences carry the same bias as the observed one.

Individual Block 3 and Block 4 trials are too short to support coherence at all, at roughly 16 s against a 20.5 s segment. For those, shape is assessed instead by correlating time-normalised individual breath cycles between devices.

**Free by-product.** The phase spectrum of the coherence gives a frequency-resolved lag estimate. If the device offset is a true time delay, phase rises linearly with frequency. If it is a fixed mechanical phase shift, phase is flat. Reported either way, as it bears on how lag should be corrected.

**Duty cycle carries a rate-dependent bias, and EH2 must control for it.** Measuring the inspiratory fraction through a band-limited signal inflates it, and the inflation grows with breathing rate: at a true duty cycle of 0.30 the measured value runs from about 0.31 at 7.5 breaths per minute to about 0.34 at 30. Any manipulation that also changes breathing rate therefore produces a duty-cycle change of the same sign for free. Blocks 3 and 4 change rate by design, and EH2 predicts an inverted U across rate, so imposed rate is included as a covariate in every shape analysis and the uncorrected values are reported alongside. This is preregistered because it would otherwise be indistinguishable from the predicted effect.

**EH3. Calibration model as hidden moderator.**

- Descriptive: how often each of the **three** candidate models is selected, across participants, and the distribution of the winner's margin over the runner-up.
- Test: whether the selected model predicts subsequent agreement between devices, and whether calibration fit predicts agreement independently of which model won.
- Rationale: participants running under different transformations are not running the same measurement, so this checks whether that heterogeneity matters.

**EH3 is interpreted only where selection is meaningful, and on this pilot it largely is not.** The three accelerometer axes are projections of one chest movement and are therefore strongly collinear, so many weight vectors reconstruct the breathing about equally well and the models score within noise of each other. In the internal pilot the winning model's margin over the runner-up had a **median of 0.013**, and 17 of 18 participants selected the same model. On that evidence the selected label is close to arbitrary and EH3 is expected to find nothing regardless of whether the underlying idea is right. It is retained as descriptive, with the margin reported alongside, and no result from it is interpreted where the margin is small.

Note also that nothing is interpreted from the calibration coefficients themselves. Under collinear axes the weights are not identified even when the reconstruction is excellent.

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

Consolidated, with the values actually used. Section 5.13 reports the resulting power.

### Design parameters, known

| Parameter | Value |
|---|---|
| Block 3 trials per participant | 9 |
| Block 4 trials per participant | median 25, range 24 to 35 observed; 20 to 60 by stopping rule |
| Paced breaths per participant, nominal | ~136 |
| Free-breathing breaths per participant, nominal | ~60 |
| Total breaths per participant, nominal | ~196 |
| **Matched breaths usable per participant** | **~42** |
| **Participant yield** | **13 of 18** |
| Free-breathing duration | 2 blocks of 120 s |
| Distinct imposed rates, Block 3 | 3 |
| Timestamp jitter, standard deviation | 35 ms |

### Variance components, from the internal pilot

Nuisance parameters only. None appears in a decision rule.

| Parameter | Value |
|---|---|
| Between-participant SD of duration bias | **35.3 ms**, the 95% profile upper bound. The point estimate was 0, at the boundary |
| Within-participant SD of breath-level differences | 308.2 ms |
| Between-participant SD of depth bias | 0.152 z |
| Between-participant SD of the coefficient of variation | 0.108 |
| Between-participant SD of the successive-difference measure | 839.5 ms |
| Alignment residual SD | median 95.2 ms |
| Calibration fit | median 0.586 uncorrected, 0.697 lag-adjusted |
| Belt-to-pacer offset | median +80 ms, range -640 to +720 ms |
| Model margin over runner-up | median 0.013 |

### Margins and assumed effects

One is derived; the rest are stated smallest effects of practical interest.

| Hypothesis | Parameter | Value | Source |
|---|---|---|---|
| H1 | Equivalence margin, breath duration | **150 ms** | Set below the derived ceiling, Section 5.13 |
| H1 | Derived ceiling, for the record | 300 ms | **Derived from H7**, Section 5.13 |
| H2 | Detection score threshold | lower bound above 0.85 | Stated |
| H2 | Tolerance, paced / free | 150 ms / 400 ms | Jitter, plus the Section 5.1 offset |
| H2 | Count agreement threshold | lower bound above 0.75 | Stated |
| H3 | Equivalence bound, duration by rate | 0.05 | Stated |
| H4 | Equivalence margin, difference in mean absolute error | 150 ms | Follows H1 |
| H5 | Agreement threshold per measure | lower bound above 0.75 | Stated |
| H6 | Equivalence margin, pre-to-post change | 0.05 on the CV scale | Stated |
| H7 | Classification agreement floor | AC1 lower bound above 0.80 | Stated |
| H7 | Coefficient equivalence margin | 75 ms | Half of H1 |
| H8 | Between-device margin, alertness slope | 75 ms | Half of H1 |
| H7 | Assumed pacer adherence | 0.80 | Assumed; see Section 5.13 |
| All | Assumed true effect | one quarter of the margin | Fixed in advance |
| All | Alpha | 0.05 | Conventional |

**H2's 150 ms tolerance and H1's 150 ms margin are unrelated quantities that now coincide numerically.** H2's is a matching window on onset times, set by timestamp jitter. H1's is an equivalence margin on breath durations, set below the H7-derived ceiling. Neither was chosen with reference to the other, and changing one does not imply changing the other.

### Notes for the simulation

1. **The binding constraint is H6.** This was anticipated as one of H3, H5, H6, H7 or H8, in a range of roughly 40 to 96 participants. It is H6, at 75, which sits inside that range. H6 has the fewest observations per participant of any confirmatory test, exactly one pre-to-post difference each, so its precision comes almost entirely from the number of participants.
2. **Equivalence tests dominate.** Six of the eight confirmatory hypotheses rest on equivalence testing, which typically needs larger samples than a difference test at the same margin. Margins should be justified as smallest effects of practical interest, not chosen for convenience.
3. **Block 4 trial count is a random variable**, governed by the stopping rule, not fixed. The simulation should draw it from a plausible distribution rather than fix it at 25, and should reflect that the trial cap truncates the upper tail.
4. **Exploratory analyses are not part of the sample size calculation.** EH1 through EH4 are reported at whatever precision the confirmatory sample affords. EH4 in particular would need well over 200 participants to test confirmatorily, which is out of scope.
5. **Variance parameters come from the internal pilot; effect sizes do not.** Section 1.7 sets out exactly what is extracted and what is blocked. Margins and expected effects must come from prior literature or from stated smallest effects of interest, since no effect-size quantity is observed before the confirmatory analysis.
6. **Assume a non-zero true bias.** Equivalence power peaks when the true difference is zero. The simulation assumes a bias of one quarter of the margin, so that the sample size does not rest on the most favourable case.
7. **Power is computed on analysable, not enrolled, participants.** Five of 18 pilot participants yielded no usable matched breaths. Every curve is drawn against enrolled participants but evaluated after that attrition.

---

## 5.13 Power simulation: method and result

One data-generating function serves the whole study, rather than one script per hypothesis, because the hypotheses share parameters and separate scripts let those drift out of sync. Power is computed **analytically** for H1, H4 and H6, where a two one-sided tests procedure on a participant-level mean has a known sampling distribution and simulating would only add Monte Carlo error, and by **simulation** for H2, H3, H5, H7 and H8. The analytic function was verified against brute-force simulation across six configurations and agreed to within 0.004.

### Deriving H1's margin ceiling from H7, then setting the margin below it

A systematic bias of X milliseconds is injected into one device's breath durations, the direction-correct classification is recomputed on both devices, and X is increased until between-device classification agreement falls below its acceptable level. That X is the smallest duration disagreement that would materially change a downstream conclusion.

The base rate is assumed, not observed, as Section 5.12 note 5 requires. It is derived from the design and from the breath-duration noise the pilot licensed, with pacer adherence assumed at 0.80, giving a direction-correct rate near 0.95.

**Derived ceiling: 300 ms**, the first bias at which Gwet's AC1 lower 95% bound falls below 0.80.

**Preregistered margin: 150 ms.** The derivation bounds what may be *tolerated*; it does not say what should be *claimed*. Three numbers frame the choice: the derived ceiling at 300 ms, the 0.80-power floor at roughly 27 ms, and the preregistered margin between them at 150 ms. Setting it at the ceiling would claim far less than the design supports; setting it near the floor would risk failing on a margin choice rather than on the instrument. Halving the ceiling is free in sample size, since the target is set by H6.

A check is built into `simulation/run_power_analysis.R`: if the derivation ever returns a ceiling below the preregistered margin, the script stops rather than silently proceeding, because the margin would then be admitting biases H7 says are consequential.

Percent agreement and AC1 across the swept range, both monotonic:

| Injected bias | 0 | 100 | 200 | 400 |
|---|---|---|---|---|
| Percent agreement | 0.914 | 0.905 | 0.882 | 0.809 |
| Gwet AC1 | 0.904 | 0.893 | 0.864 | 0.759 |
| Cohen's kappa | +0.19 | +0.04 | +0.06 | +0.14 |

The kappa row is why the decision statistic changed; see Section 5.9.

### Power by sample size

Enrolled participants, with attrition applied.

| N | H1 | H2 | H3 | H4 | H5 | H6 | H7 | H8 |
|---|---|---|---|---|---|---|---|---|
| 10 | 0.99 | 0.18 | 0.33 | 0.99 | 0.34 | 0.00 | 0.98 | 0.65 |
| 20 | 1.00 | 0.42 | 0.75 | 1.00 | 0.63 | 0.00 | 1.00 | 0.94 |
| 30 | 1.00 | 0.56 | 0.92 | 1.00 | 0.75 | 0.27 | 1.00 | 0.99 |
| **40** | 1.00 | 0.71 | 0.96 | 1.00 | 0.88 | 0.46 | 1.00 | 1.00 |
| 50 | 1.00 | 0.78 | 0.99 | 1.00 | 0.94 | 0.61 | 1.00 | 1.00 |
| 60 | 1.00 | 0.86 | 1.00 | 1.00 | 0.96 | 0.70 | 1.00 | 1.00 |
| **75** | 1.00 | 0.93 | 1.00 | 1.00 | 0.99 | **0.80** | 1.00 | 1.00 |
| 90 | 1.00 | 0.96 | 1.00 | 1.00 | 1.00 | 0.87 | 1.00 | 1.00 |
| **100** | 1.00 | 0.97 | 1.00 | 1.00 | 1.00 | 0.90 | 1.00 | 1.00 |

Bold rows are the three points fixed by the sampling plan: the interim re-estimation at 40, the target at 75, and the hard cap at 100.

**Three columns are not what they appear, and should be read with the qualifications attached rather than at face value.**

| Column | What the number actually is |
|---|---|
| **H4** | H1's participant-level variance applied to H4's margin. H4's own variance is a between-device difference in error against the pacer, which is blocked, so it cannot be estimated under blinding. Read this as "not separately estimable", not as 1.00 |
| **H2** | Precision growth at a **stated** match proportion. Match proportion is blocked, so this is not a prediction of the effect |
| **H5** | Precision growth at a **stated** agreement level, for the same reason |

Only H1, H3, H6, H7 and H8 rest on a variance the pilot licensed for the quantity actually being tested.

Smallest N reaching 0.80: H6 at 75, H2 at 60, H5 at 40, H3 at 25, H8 at 15, and H1, H4 and H7 at 10 or below.

**These figures already reflect the tightened margins.** H1 and H4 run at 150 ms rather than the 300 ms ceiling, and H7's coefficient test and H8 at 75 ms rather than 150 ms. Halving every margin moved exactly one hypothesis: H8, from 10 enrolled to 15. H6 is unchanged at 75, so the stronger claims cost nothing in recruitment.

**The target is set entirely by H6**, the pre-to-post change in the coefficient of variation, and H6 depends on one pilot variance component: a between-participant CV spread of 0.1079, estimated from 18 participants.

That estimate carries its own sampling error, and it is larger than it may appear. Under normal theory the relative standard error of a standard deviation estimated from *n* observations is approximately 1/sqrt(2(n-1)), which at n = 18 is **17.1%**. The bands below are therefore multiples of that standard error rather than round percentages, so the table states the uncertainty the design actually faces:

| Assumed CV spread | Power at N = 75 | N for 0.80 power |
|---|---|---|
| 0.0894 (1 SE lower) | 0.92 | 53 |
| **0.1079 (pilot estimate)** | **0.80** | **75** |
| 0.1264 (1 SE higher) | 0.67 | 103 |
| 0.1449 (2 SE higher) | 0.52 | 133 |

**A one standard error band on this single parameter spans a target of 53 to 103.** That is the honest statement of what is known about the sample size at this point, and it is wider than the initial draft of this section implied by using illustrative ten per cent bands. The point estimate remains the basis for the target, since it is the best available and the design must state a number, but the width is why the interim re-estimation matters and why the hard cap must sit above 75.

Note the asymmetry. Overshooting the target costs participants; undershooting costs the hypothesis. If the true spread is one standard error above the estimate, recruiting to 75 and stopping leaves H6 at **0.67 power**, which is below the level at which a null result is interpretable.

### What precision the design actually buys

The flat curves invite the wrong reading, that these tests are powerful. They are not powerful; they are undemanding. The useful question is the inverse one: holding power fixed, how small a margin could this design defend?

The participant-level standard deviation of the duration-bias mean is

> sqrt( 35.3^2 + 308.2^2 / 42 ) = **59.2 ms**

so at 75 enrolled, meaning 54 analysable, the standard error on that mean is about 8.1 ms. The smallest margin reaching each power level, on the same scale as H1 and H4:

| N enrolled | N analysable | Margin at 0.80 power | Margin at 0.90 power |
|---|---|---|---|
| 50 | 36 | 33.8 ms | 39.5 ms |
| 60 | 43 | 30.8 ms | 36.0 ms |
| **75** | **54** | **27.4 ms** | **32.0 ms** |
| 90 | 65 | 24.9 ms | 29.1 ms |
| 110 | 79 | 22.5 ms | 26.3 ms |

This is what moved H1's margin. The originally derived 300 ms ceiling was roughly **eleven times** looser than the design could support. The preregistered 150 ms is about **5.5 times** the floor, which is deliberate headroom rather than slack.

**Why not simply preregister 27 ms.** The table inherits the convention of Section 5.12, that the assumed true bias is one quarter of the margin, so margin and assumed effect shrink together. If the true between-device bias is genuinely near zero, a margin near 27 ms is establishable. If the true bias is, say, 100 ms, then no margin below about 100 ms can be established at any sample size whatever, and preregistering 27 ms would convert a study that succeeds into one that fails for reasons unrelated to the instrument's adequacy. The achievable bound depends on the answer and therefore cannot be fixed in advance.

There is a specific reason to expect the true duration bias to be small, which is part of why 150 ms is defensible: **a constant between-device onset offset cancels in a duration**, since a duration is a difference of two onsets. The block-dependent offset predicted in Section 5.1 is an onset effect, and it contaminates H1 only to the extent that it *varies* within a block rather than sitting at a constant value. That is an argument for a tight margin, not a guarantee, which is why the headroom is retained.

**The commitment that remains.** Alongside the preregistered decision at 150 ms, we will report the **achieved equivalence bound**: the smallest margin at which both one-sided tests still reject, computed as the larger of the two absolute 90% confidence limits on the participant-level mean, that being the interval corresponding to two one-sided tests at 0.05. That number is a direct readout of what the data support, it is bounded below by the table above, and it costs nothing in sample size. It converts the saturated tests from "passed a fixed test" into a quantitative statement of agreement. The 150 ms margin remains the confirmatory decision rule, so this adds information without re-tuning a preregistered claim after the fact.

### Honest limits of this analysis

**Three curves are flat and therefore uninformative.** H1, H4 and H7 are saturated across the whole range, at 0.98 or above from 10 enrolled. That follows from a between-participant standard deviation of 35.3 ms against margins of 75 to 150 ms, and it is a real consequence of those margins rather than an artefact. Halving the margins from the derived ceiling narrowed the gap without closing it: 150 ms is still several times the precision available. The achieved equivalence bound above is the intended remedy. H8 is no longer in this group, having moved to 0.65 at 10 enrolled once its margin was halved.

**H2 and H5 rest on stated rather than observed effects.** Match proportion and every agreement coefficient are blocked by Section 1.7, so no pilot value exists. Their curves show how precision grows with sample size at an assumed effect; they are not predictions of the effect itself.

**H4 borrows H1's participant-level variance.** The estimands differ, and the correct variance cannot be obtained without disclosing an error relative to the pacer, which is blocked. Because H4 is saturated at every sample size, this does not affect the target.

**The between-participant variance was estimated at a boundary.** See Section 1.7. The upper bound is used throughout; the point estimate of zero is not.

---

# 6. Open items

| Item | Status |
|---|---|
| BN-RSPEC bandwidth | **Resolved: DC to 10 Hz** respiration, 0.05 to 150 Hz ECG, Sections 1.3 and 1.6 |
| Sample size | **Resolved: 75 enrolled**, Sections 1.2 and 5.13 |
| Pilot participant list | **Resolved**, recorded in Section 1.7 |
| All equivalence margins and thresholds | **Resolved**, Sections 5.12 and 5.13 |
| Interim re-estimation point and hard cap | **Resolved: 40 and 100 enrolled**, Sections 1.2 and 1.7 |
| H1's preregistered margin | **Resolved: 150 ms**, below the 300 ms derived ceiling, Sections 5.3 and 5.13 |
| Signal quality index threshold | **Resolved: none required.** Continuous in H6, flagged at a fixed 0.50, Section 5.8 |
| Welch parameters for the coherence analysis | **Resolved: 512 samples, 50% overlap, Hann**, Section 5.11 |

**Nothing is outstanding.** Every equivalence margin, decision threshold, sample size parameter and analysis-procedure detail is now fixed and stated. The signal quality index item closed by removing the need for a threshold rather than by choosing one, since tuning a cut point on the data H6 is tested against would have been a route for the outcome to influence the rule.

## Limitations to state

1. **Belt order is not counterbalanced.** The accelerometer is always against the skin and always inside the stretch belt. Any systematic device difference is confounded with placement.
2. **Calibration is brief.** Nineteen seconds, roughly 3,900 samples, to fit four parameters. Extending the fit to the paced blocks would be more stable but would compromise the pacer-accuracy analysis in H4, since the model would then be fitted to predict the very signal it is tested against.
3. **The rate range is narrow.** Block 3 spans 3 to 5 s. Claims about rate dependence rest largely on Block 4, where rates are sampled unevenly around each participant's own threshold.
4. **Condition onset is computed, not measured.** The event code marking it was removed from the software to protect pacer timing. It is reconstructed as trial start plus two baseline breaths, and therefore inherits any jitter in the trial-start code.
5. **Alignment absorbs browser clock wander.** The linear drift correction removes roughly 380 ms of divergence across a session. Analysis of the accelerometer timestamps shows a comparable amount of slow wander in the browser clock, so the correction is largely absorbing browser timing rather than acquisition-hardware error.

6. **A large share of breaths does not survive matching.** Roughly 42 of about 196 nominal breaths per participant yield a usable between-device duration comparison, and in the internal pilot 5 of 18 participants yielded none at all. The strict rule that produces this is deliberate and is defended in Section 5.3, but it means the study measures agreement on the breaths both devices resolve cleanly, which is a more favourable subset than all breaths. H2 and the device-specific missingness reported under H7 are what speak to the breaths that do not survive; H1 should not be read as a statement about them.

7. **Calibration quality is mixed.** Across the internal pilot the Block 1 fit had a median of 0.586 and a lower quartile of 0.350, with 5 of 18 participants below the 0.40 flag. Lag adjustment raises the median to 0.697, so much of the shortfall reflects the mechanical confound between fit and offset rather than poor weights. Poor calibration is flagged and retained, not excluded, but it plausibly explains the participants who contribute no usable matched breaths, and any conclusion about the accelerometer is a conclusion about it as calibrated by this brief procedure.

8. **The margins remain wide relative to the measured precision, though less so than in the first draft.** H1, H4 and H7 are saturated at every sample size considered. The margins were halved before registration, H1 and H4 from the 300 ms derived ceiling to 150 ms and H7 and H8 from 150 ms to 75 ms, which strengthens the claims at no cost in recruitment. Even so, 150 ms on a breath of roughly 4000 ms is still about 5.5 times the 27 ms the design could support, so readers should take the margin, not the power, as the measure of what is being asserted, and should read the achieved equivalence bound committed to in Section 5.13 rather than the pass or fail at 150 ms.

9. **The sample size rests on a single pilot variance component, known to about 17%.** The target of 75 is set by H6 alone, through a between-participant CV spread estimated from 18 participants. The relative standard error of that estimate is 17.1%, and a one standard error band on it spans a target of 53 to 103. The target is therefore a best estimate rather than a requirement, and the interim re-estimation is the mechanism that resolves it. See the sensitivity table in Section 5.13.
