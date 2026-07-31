# BreathBelt — COM event triggers

How BreathBelt sends event markers to the physio recording equipment, what was
fixed (May 2026), and what's left to do.

## Background

BreathBelt emits numeric event codes over a serial COM port so that the physio
recording (ADInstruments PowerLab + LabChart, or Biopac) gets time-stamped
comments aligned to the game's phases and trials.

On the lab testing computer the COM device is a **Black Box ToolKit (BBTK) USB
TTL Module** — *not* a transparent USB-to-TTL passthrough. It has its own ASCII
command protocol and drives 8 TTL output lines into the PowerLab digital input.

### BBTK USB TTL Module protocol

(Confirmed from the blackboxtoolkit.com "USB TTL Module v1" guide.)

- **Port:** 115200 baud, 8 data bits, no parity, 1 stop bit, no flow control.
- **Init:** send `"RR"` once to reset the module and clear all output lines.
- **Event mark:** send a **two-character UPPERCASE hex string** = the byte value
  to place on the 8 TTL lines. `"01"` = value 1, `"0A"` = 10, `"0C"` = 12,
  `"FF"` = 255. Range `00`–`FF`. **No newline / terminator.**
- **Clear:** send `"00"`.
- **Pulse shape:** set value, hold ~25 ms, then `"00"`. PowerLab sees a clean
  edge. (Matches the BBTK PsychoPy example's `core.wait(0.025)`.)

## What was wrong (and fixed)

The old code sent decimal `` `${value}\n` ``. Two bugs:

1. **Codes 10–12 never registered.** The module reads the two chars as *hex*, so
   decimal `"10"/"11"/"12"` became hex `0x10/0x11/0x12` = lines 16/17/18, which
   LabChart had no comment for. Codes 0–9 only worked by luck (decimal and hex
   `"0"`–`"9"` are identical strings). Fixed by sending zero-padded uppercase hex
   (`0A`/`0B`/`0C`).
2. **Flakiness ("had to send it multiple times").** The trailing `"\n"` broke the
   module's strict 2-char framing and desynced following commands. Fixed by
   dropping the newline.

The earlier dead-end theories (hold/re-assert the byte for 20 ms, `byte − 0x30`
offset, digit-parser, baud) were all artifacts of reverse-engineering an
accidental protocol collision before the BBTK docs were found. Ignore them.

## Code vocabulary

| Code | Hex  | Event                | Fired from |
|------|------|----------------------|------------|
| 1    | `01` | session start        | BreathBelt.jsx (baseline onStart) |
| 2    | `02` | pre-baseline start   | BaselineScreen |
| 3    | `03` | pre-baseline end     | BaselineScreen |
| 4    | `04` | phase 2 start        | BreathBelt.jsx |
| 5    | `05` | phase 2 end          | BreathBelt.jsx |
| 6    | `06` | phase 3 start        | BreathBelt.jsx |
| 7    | `07` | phase 3 end          | BreathBelt.jsx |
| 8    | `08` | post-baseline start  | BaselineScreen |
| 9    | `09` | post-baseline end    | BaselineScreen |
| 10   | `0A` | trial start          | useTrialRunner |
| 11   | `0B` | condition onset      | useTrialRunner |
| 12   | `0C` | trial end            | useTrialRunner |
| 13   | `0D` | session end          | BreathBelt.jsx (after endSession + on mid-session unmount) |

**Code 0 / `00` is the line-clear, NOT an event marker.** Session end was moved
from 0 → **13** because `00` is the BBTK clear command and couldn't double as a
distinct marker.

## Trigger-device selector

Different testing rigs use different equipment, so the session-setup screen has a
**Trigger device** dropdown (`TRIGGER_DEVICES` in `constants.js`):

- `AD_BBT` (default) — AD Instruments PowerLab + BBTK. **Implemented.**
- `Biopac_Left` — Biopac via parallel-port card, left rig. **Stub only.**
- `Biopac_Right` — Biopac via parallel-port card, right rig. **Stub only.**

`useBeltConnection` holds `triggerDeviceRef` + `setTriggerDevice`; `BreathBelt.jsx`
applies the choice on "Continue". `sendTrigger` branches on it: `AD_BBT` runs the
BBTK hex protocol; the Biopac options currently just `console.warn`. The chosen
device is saved to `belt_sessions.trigger_device`.

## Files

| File | What changed |
|------|--------------|
| `src/games/BreathBelt/hooks/useBeltConnection.js` | `connectCOM` sends `RR` on connect (AD_BBT only); `sendTrigger` writes 2-char hex + `00` clear, branching per device; added `triggerDeviceRef` + `setTriggerDevice`. |
| `src/games/BreathBelt/BreathBelt.jsx` | Device dropdown on setup screen; session-end code 0 → 13 (both call sites); passes `triggerDevice` to `endSession`; updated vocabulary comment. |
| `src/games/BreathBelt/hooks/useBeltSession.js` | `endSession` accepts and persists `trigger_device`. |
| `src/games/BreathBelt/constants.js` | `TRIGGER_DEVICES`, `DEFAULT_TRIGGER_DEVICE`. |
| `supabase/migrations/20260529_belt_trigger_device.sql` | Adds `belt_sessions.trigger_device text`. |
| `scripts/trigger-tester.html` | Standalone BBTK protocol tester (see below). |

### Standalone tester — `scripts/trigger-tester.html`

No-build diagnostic page (Chrome/Edge). Default mode "BBTK hex": sends `RR` on
connect, 2-char hex per code, `00` clear. Has a Reset (RR) button, code buttons
(incl. 13 and a clear), custom byte send, a byte Sweep tool, and ASCII/raw modes
for low-level probing. Just open it in a browser — no server needed.

## Status

- Code changes complete and the app builds clean (`npm run build`).
- **Not yet done on hardware:** the DB migration has not been applied, and no full
  session has been run end-to-end against the rig.

## Next-steps checklist

- [X] **Apply the migration** (Supabase SQL editor / MCP / CLI). Must happen
      before the next real session or `endSession` insert fails:
      ```sql
      ALTER TABLE belt_sessions ADD COLUMN IF NOT EXISTS trigger_device text;
      ```
- [ ] **Add a LabChart comment definition for value 13** (session end). Without
      it, code 13 fires but shows no comment — same gap that hid 10–12 before.
      While there, confirm 10/11/12 comments exist.
- [ ] **Sanity-check with the standalone tester first** (`scripts/trigger-tester.html`):
      connect, BBTK hex mode, click 1–13, confirm each shows the right comment in
      LabChart (esp. 10–12 and 13).
- [ ] **Run a full BreathBelt session** on the rig: choose `AD_BBT` at setup, go
      through calibration → baseline → phase 2 → phase 3 → post-baseline → end.
      Verify every marker lands in LabChart (table above) and that the run is
      reliable (no missed/duplicated triggers).
- [ ] **Verify persistence:** the new `belt_sessions` row has
      `trigger_device = 'AD_BBT'`.
- [ ] **(Later) Implement the Biopac devices.** Known issue: the FSM does the
      Web Serial `COM_CONNECT` step *before* the device is chosen, which only
      suits AD_BBT. Biopac parallel-port cards aren't serial and a browser can't
      drive a parallel port directly — this will need a different transport
      (e.g. a small local helper) and likely a reorder of the connect flow.
      `sendTrigger`'s `Biopac_Left`/`Biopac_Right` branches are stubs awaiting
      the actual trigger protocol for each rig.
