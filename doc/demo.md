# Demo notes (for a reader in a hurry)

**What the demo walk is:** the developer's own apartment → lobby →
package-check route, walked live with the goal *"As I walk, keep
watching the camera and tell me what you see,"* phone camera as the
source, server tier backed by Muse Spark.

**What Dave said on that walk** (session 2026-11-04,
14:41–14:44 local): a carpeted hallway with wall lights; then, reading a
real sign verbatim, "NO SMOKING" (the digest held the full text:
*IN CASE OF FIRE / USE STAIRS UNLESS / OTHERWISE INSTRUCTED / NO
SMOKING / IN ELEVATORS UNDER PENALTY OF LAW*); a doorway; a dim
hallway; a close-up of the elevator control panel naming the floor
buttons; and the lobby tile floor. Six spoken reports, each about a
new scene, none repeated.

**What made that possible, in order of measured effect:**

1. Accurate on-device OCR (Vision `.accurate`, orientation-corrected
   frames). Before this change the same route produced zero real
   words in 122 scene digests; after it, the sign exists.
2. Digest coalescing: while a model call is in flight (observed
   5–25 s), stale queued digests are dropped rather than judged late.
   That walk dropped 100 stale digests and kept decisions current.
3. The signage fast-lane: newly appearing high-saliency items (sign,
   entrance, OCR text ≥0.75) bypass the describe cooldown.
4. Client-side veto overrides: a model answering "nothing new" —
   in prose — about a scene the on-device gate measured as changed
   (≥0.80) no longer silences the report.

**Known limitations, honestly (all in the logs):**

- The building's elevator is a network dead zone; mid-walk outages
  swap in the on-device Apple tier, which is weaker and rate-limited.
  On the demo walk the package/mail area was reached during one such
  gap and escalated correctly but was never described by the server.
- Frontier model latency is 5–25 s per escalation. Coalescing keeps
  speech relevant, not instant; continuous fast panning will always
  outrun this pipeline.
- The gate's silence/speech line is tuned on one user's known routes.
  Wider corpora (TRD-003 §7, double opt-in) are parked post-hackathon.
