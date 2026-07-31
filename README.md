# BreathBelt: Comparing an Accelerometer Chest Strap Against a Stretch Respiration Belt

Does a Polar H10 accelerometer chest strap measure breathing closely enough to a
BioPac stretch respiration belt to be treated as interchangeable? Participants
wear both simultaneously through calibration, free breathing, fixed-rate paced
breathing, and an adaptive staircase, in one lab session. A visual pacer supplies
independently known ground truth during the paced blocks.

Part of the RADlab behavioural interoception programme.

---

## STOP: read this before opening any data file

Eighteen completed participants are an **internal pilot** for variance
estimation. They remain in the confirmatory sample. That is only legitimate if
nothing beyond a fixed whitelist is ever observed.

Opening an RDS to check that agreement "looks reasonable" destroys the protection
permanently. It cannot be undone by deciding to ignore what was seen.

1. Never print, plot, or summarise participant outcome data. Not to debug, not
   to sanity-check, not "just the first few rows".
2. Never compute a mean bias, correlation, agreement coefficient, match rate,
   timing difference, or any error relative to the pacer, outside the sanctioned
   script.
3. The only permitted route to pilot outcome data is
   `scripts/02_estimate_variance_components.R`. Run it, read its report, stop.
4. To test code, use participant 14542 alone, or synthetic data. Even there, do
   not inspect agreement quantities.
5. If a script fails on real data, debug from the error and the code, not from
   the data that caused it.
6. Do not add anything to `WHITELIST` without Norm's explicit approval.

Structural metadata is not outcome data and is fine to inspect: file names, phase
labels, block durations, trigger codes, channel counts, participant identifiers,
seat assignments. The dividing line is whether the quantity could inform a
Section 5 decision rule. Section 1.7 of the pre-registration keys each blocked
quantity to the hypothesis it protects.

---

## Status

Data collection paused at 18 complete participants. Nothing has been analysed.
The immediate goal is to finish the pre-registration, run a power simulation, and
justify a sample size before looking at any outcome.

| Task | State |
|---|---|
| 1. Correct the preprocessing pipeline (pacer-target calibration fit) | in progress |
| 2. Reconcile onset detection between scripts | blocked, see open items |
| 3. Generalise and batch-run preprocessing | not started |
| 4. Run the variance extraction | blocked on 1 to 3 |
| 5. Build the simulation machinery | not started |
| 6. Set the equivalence margins | not started |

---

## Layout

```
prereg/            Pre-registration draft (controlling document) and handoff
R/                 Reusable analysis functions
scripts/           Numbered entry points, run in order
simulation/        Power simulation machinery (Task 5)
docs/              Verified facts, discrepancy log, decisions
reference/
  radlab_snapshot/ Read-only copies of the experiment source, with commit SHA
  legacy_app_ts/   Superseded TypeScript app, kept for provenance only
Data/              Raw and tabular data (gitignored, shared drive only)
  acq_physio/      BioPac .acq, one file per session, both seats
  bt_physio/       Polar H10 accelerometer and heart-rate CSVs
  tables/          Exported session, trial, and questionnaire tables
Analysis/
  output/          Per-participant RDS (gitignored)
  pilot_variance/  Variance extraction output (gitignored)
Materials/         Consent and debriefing forms
archive/           Superseded scripts and dev-test sessions
```

`prereg/breathbelt_prereg_draft.md` is the controlling document. Everything else
serves it.

## Data is never tracked

`Data/`, `Analysis/output/`, `Analysis/pilot_variance/`, and `archive/Pilot/` are
excluded by `.gitignore`. No participant data reaches GitHub, private repo or
not. If you add a data directory, add it to `.gitignore` in the same commit.

---

## Running

Requires R 4.5 or newer. Scripts run in numeric order and expect the shared drive
mounted at `I:`.

```
Rscript scripts/01_batch_prep.R                    # Task 3, not yet written
Rscript scripts/02_estimate_variance_components.R  # Task 4, run once
Rscript scripts/03_power_simulation.R              # Task 5, not yet written
```

`02` refuses to run on RDS files whose calibration weights were fitted against
the BioPac signal rather than the reconstructed pacer, because those absorb
participant-specific variance and would yield an optimistic sample size.

---

## Open items needing Norm

| Item | Blocks |
|---|---|
| RSP100C gain and filter settings | Methods completeness |
| Location of `Intero2025_BehaviourLedBreathAnalysis.R` | Task 2, and the H7 base rate |
| Run sheet for participant 14425 (seat conflict, see `docs/discrepancies.md`) | Task 3 |
| Realistic recruitment ceiling | Task 5 |
| Interim re-estimation point and hard cap | Section 1.7 step 6 |

See `docs/discrepancies.md` for everything found that contradicts the current
drafts, and `CONTEXT.md` for architecture context across sessions.
