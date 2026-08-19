# BreathBelt pre-registration: revision plan

Started 2026-08-14, against `prereg/breathbelt_prereg_draft.md` (994 lines).

**What this is built from.** Not from reviewer feedback. The Google Doc circulated on 2026-08-12 has received no edits and no comments: two independent exports, taken two days apart, contain the identical 14,908 words, differing only in table alignment markers. So this plan is assembled from the document's own open items, plus a consistency scan of the draft against the repo files that describe the same decisions.

Tiers are ordered by what blocks submission, not by effort.

---

## Status as of 2026-08-15: all tiers complete

| Item | Status |
|---|---|
| R1 Interim point and hard cap | **Done.** 40 and 100 enrolled, with the full procedure in Section 1.7 |
| R2 H1 margin | **Done.** Tightened to 150 ms against a 300 ms derived ceiling; H4 followed to 150, H7 and H8 to 75 |
| R3 BN-RSPEC bandwidth | **Done.** DC to 10 Hz respiration, 0.05 to 150 Hz ECG. Manufacturer product page, not the PDF datasheet, which blocks automated retrieval. Worth confirming against the datasheet |
| R4 Stale tight-band reference | **Done.** Filter convention now covers the bands actually in use |
| R5 `CONTEXT.md` | **Done.** Three models, two-copy chain, plus a shared-detector entry that was missing |
| R6 `docs/discrepancies.md` | **Done.** All six C-entries resolved |
| R7 Signal quality index | **Done, by removing the threshold rather than choosing one.** Continuous in H6, fixed 0.50 anchor for flagging |
| R8 Welch parameters | **Done.** 512 samples, 50% overlap, Hann, 1,000 phase-randomised surrogates |
| R9 H4 borrowed variance | **Done.** Marked in the Section 5.13 table as not separately estimable |
| R10 H2 and H5 stated effects | **Done.** Dashed in the figure, asterisked in the legend, footnoted, and tabulated in Section 5.13 |
| R11 Achieved equivalence bound | **Done.** Now specifies the 90% interval corresponding to two one-sided tests at 0.05 |

**No `[NEEDS INPUT]` or `[SIM]` item remains in the pre-registration.**

Two things carried forward rather than closed:

- The BN-RSPEC bandwidth should be checked against the actual datasheet. Two independent searches agree, but both trace to BIOPAC's own product-page text, so it is one source restated rather than two.
- Nothing is committed to git.

---

## Tier 1. Decisions only Norm can make

These are substantive scientific judgements, not editorial work. Each is already flagged `[NEEDS INPUT]` in Section 6.

### R1. Interim re-estimation point and hard cap

**Why it is first.** The target of 75 rests on a between-participant CV spread of 0.1079 estimated from 18 participants. Section 5.13's sensitivity table shows a ten per cent error in that single number moves the target between 61 and 90. The re-estimation is the mechanism that catches this, and it is currently unspecified in both timing and bound.

Two values needed:

- **Interim point.** A sample size at which the variance is re-estimated once. It should be far enough in to sharpen the estimate materially and early enough to act on. Somewhere around 40 enrolled is the obvious candidate, but that is a recruitment-logistics call as much as a statistical one.
- **Hard cap.** The plan should say explicitly that the cap sits **above** 75, since the 60 to 90 band is roughly symmetric around the target and a cap at 75 forecloses the upper half of it.

Section 1.7 sequence step 6 and the Section 6 note both need the numbers written in.

### R2. H1's margin: keep 300 ms, or lower it

Section 5.13 lays out the position. 300 ms is derived from H7 and defensible. It is also roughly eleven times looser than the 27.4 ms the design could support at N = 75.

The added commitment to report the **achieved equivalence bound** already recovers most of the lost information, so this is no longer urgent. But it remains a real choice, and the honest framing is: is a 300 ms disagreement, on a breath of roughly 4000 ms, genuinely the smallest difference that would matter for how this belt gets used? If the answer is no, the margin should come down and the derivation in 5.13 should be re-run against whatever the new criterion is.

Note the asymmetry in the risk. Lowering the margin cannot be undone after seeing data, and if the true bias is larger than the new margin the test fails for reasons unrelated to instrument adequacy.

### R3. BN-RSPEC datasheet bandwidth

Section 1.6, to be cited rather than measured. Smallest item here, and the only one that is pure lookup.

---

## Tier 2. Internal inconsistencies found in the scan

These are defects, not preferences. I can fix all three.

### R4. The prereg contradicts itself on the dropped calibration band

`prereg/breathbelt_prereg_draft.md:460`, inside the filter specification at Section 5.1 step 4:

> The same convention applies to the 0.6 Hz low-pass and to the narrow 0.10 to 0.4 Hz band used by the tight calibration model variants.

The tight variants were dropped one step later, at step 5 (`:467`), and Section 4.5 (`:415`) states the narrow-band variants were dropped. The filter-order convention sentence is a survivor from the six-model draft and now describes a band the analysis does not use.

**Fix.** Drop the trailing clause. The convention statement still needs to cover the 0.6 Hz low-pass and should now also cover the 2.0 Hz measurement band, which the two-copy design introduced and which the sentence never picked up.

### R5. `CONTEXT.md` describes the superseded pipeline

Three stale passages:

- `:140` "Combine by calibrated weights, then low-pass at 0.6 Hz". This is the single-band chain. The design is now two filtered copies, detect at 0.6 Hz and measure at 2.0 Hz.
- `:154` to `:155` "Six candidate calibration models ... (`mlr` and `pca`, each on a wide or tight band, `mlr` also with a 0.6 Hz smooth)". Now three.
- `:158` to `:162` follow-on reasoning about all six scoring within noise.

**Fix.** Rewrite to three models on the wide band and the two-copy filter chain. The collinearity argument at `:162` survives unchanged and should be kept, since it is the reason EH3 is expected to find nothing.

### R6. `docs/discrepancies.md` still names kappa as H7's rule

- **C3** (`:343` to `:345`) sets H7 at "kappa lower 95% bound above 0.60". Superseded: Gwet's AC1, lower bound above 0.80. C3 should be marked resolved with the degeneracy evidence, since C3 is the entry that predicted the prevalence artefact and it deserves to record that it was right.
- **C4** (`:371`, `:379`, `:383`) refers to kappa throughout in describing device-specific missingness. The substance is now in Section 5.9 test 3; the wording needs updating to AC1.
- **C5** (`:604`) is titled "Calibration fit and device lag are not independent". "Device lag" was renamed belt-to-pacer offset for the reasons in Section 5.1.
- **C1, C2, C6** are applied in the current draft but not marked as such.

**Fix.** Update C3, C4 and C5 wording; add resolution status to C1, C2, C5 and C6.

---

## Tier 3. Specification gaps the draft already admits

Both are named in Section 6 as "to be specified before analysis". They do not block registration if the commitment to specify them in advance is explicit, but they are better closed than carried.

### R7. Signal quality index tuning procedure

The last remaining `[SIM]`. Sections 4.5 and 5.8. The index is computed offline and its degradation threshold is to be tuned on these data. Tuning a threshold on the same data used for H6 needs a stated procedure that cannot leak the H6 outcome, which is the part actually worth writing down.

### R8. Welch parameters for the coherence analysis

Section 5.11, EH2. Segment length and overlap, plus the phase-randomised null. Exploratory, so lowest stakes on this list.

---

## Tier 4. Judgement calls worth a second look before this is public

Not defects. Places where a hostile reader has a fair point and the draft should either answer it or concede it more plainly than it does.

### R9. H4 borrows H1's participant-level variance

Section 5.6 and the Section 5.13 limits both disclose this. The defence is that H4 is saturated at every N so it cannot affect the target, which is true. The weakness is that it also means H4's power figure is not really H4's. Consider stating the power for H4 as "not separately estimable under blinding" rather than as 1.00, which reads as a stronger claim than the evidence supports.

### R10. H2 and H5 rest on stated rather than observed effects

Disclosed in Sections 5.4, 5.7 and 5.13. Unavoidable, since match proportion and every agreement coefficient are blocked. Worth checking that the H2 curve in the figure carries the same caveat the text does, because a reader who looks only at the figure will read 0.93 at N = 75 as a prediction.

### R11. Verify the achieved equivalence bound is operationally precise

Section 5.13 defines it as "the larger of the two absolute confidence limits on the participant-level mean". That is correct for a symmetric TOST but should be checked against how it will actually be computed, and stated with the confidence level attached, so it is a genuine pre-commitment rather than an intention.

---

## Suggested order

1. R4, R5, R6 first. Mechanical, and they remove contradictions that would undermine a reader's trust in everything else.
2. R1 next, since it is the only Tier 1 item that changes a number in the document.
3. R2 and R3 whenever the answers arrive.
4. R7, R8, then Tier 4 as polish.

## Not in scope here

Nothing has been committed to git. The working tree carries four modified files and six untracked paths, including `R/onsets.R`, `simulation/` and `reference/respkit_snapshot/`. Worth a commit before revisions start, so this round is reviewable as a diff.
