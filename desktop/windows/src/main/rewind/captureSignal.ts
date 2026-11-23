// The cheapest possible "the newest stored rewind frame changed" signal.
//
// Kept in a dependency-free leaf module (no electron / koffi / better-sqlite3) so
// pollers can read it WITHOUT importing the heavy capture stack — that import
// would break their plain-node unit-test isolation (the assistant coordinator's
// suite mocks `ipc/db` precisely to avoid loading the native binding).
//
// captureService is the sole writer (it calls `markRewindCaptured` each time it
// stores a frame). Readers (the assistant coordinator's poll tick) compare the
// value across ticks: while it has not advanced, the DB's newest frame is the same
// row they already handled, so the DB read can be skipped entirely.
let lastCaptureAtMs: number | null = null

// LOCAL ADAPT (XiaoWo): mirror of the user's Rewind captureEnabled setting, kept
// in this dependency-free leaf (same reason as the signal above) so pollers —
// the assistant coordinator — can skip stale-frame work without importing the
// heavy capture stack. Defaults to true (capture-on) to match the coordinator's
// pre-startup assumption in captureService.
let captureEnabled = true

/** Mirror the user's captureEnabled setting (called by captureService on load
 *  and on every settings update). */
export function setRewindCaptureEnabled(enabled: boolean): void {
  captureEnabled = enabled
}

/** Whether rewind capture is currently storing frames (this run's view). */
export function isRewindCaptureEnabled(): boolean {
  return captureEnabled
}

/** Record that a frame was just stored, tagged with its capture timestamp. */
export function markRewindCaptured(tsMs: number): void {
  lastCaptureAtMs = tsMs
}

/** Timestamp of the most recently stored frame this run, or null if none yet. */
export function lastRewindCaptureAtMs(): number | null {
  return lastCaptureAtMs
}
