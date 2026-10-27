# TRD-001 — Image Capture and Digests

Depends on: [TRD-000](000-overview.md)

## 1. Job

Keep a cheap, steady stream of digests flowing to the classifier from
whichever camera the user picked. This component knows nothing about
goals or speech.

## 2. Frame sources

```swift
protocol DigestSource {
    var sourceID: String { get }   // "iphone-camera" | "meta-glasses" | "mock"
    func stream(sessionID: UUID, interval: TimeInterval) -> AsyncStream<FrameDigest>
    func stop()
}
```

- **CAP-01** Sources are interchangeable behind this protocol; swapping
  phone for glasses changes no downstream code.
- **CAP-02** The phone source uses AVFoundation, throttled to the session
  interval (default 1 s, debug-configurable). A scripted "mock walk"
  source exists for demos and tests with no hardware at all.
- **CAP-03 — Meta glasses via DAT 1.0 are an MVP source**, not a stretch
  goal. Integration facts (from Meta's published iOS sample and docs):
  Swift packages `MWDATCore` / `MWDATCamera` / `MWDATMockDevice`
  (iOS 17+); Developer Mode is enabled in the Meta AI app (Settings →
  App Info → tap version five times); the app registers through Meta AI
  and is called back on a custom URL scheme — a plain scheme such as
  `properdave://`, no hosted universal link, no domain to stage.
  Credentials (`MetaAppID`, `ClientToken`) come from a project in the
  Wearables Developer Center keyed to the app's bundle ID, and are
  build-time values from a git-ignored secrets config, never committed.
  In Developer Mode the SDK accepts app ID `0`, so development is not
  blocked on paperwork.
- **CAP-04** The glasses stream is sampled *down* to the session interval
  and fed through the same digest extraction as phone frames, so a digest
  means the same thing from either source.
- **CAP-05** Dynamic XCFrameworks must be embedded and the app binary's
  runpath must include `@executable_path/Frameworks`; without both, the
  app is killed by dyld at launch. (Written down because it is exactly
  the class of thing that otherwise costs a confused afternoon.)

## 3. Digests

- **CAP-06** Extraction runs on device (Vision classification + text
  recognition). A digest carries: session ID, monotonic sequence,
  timestamp, source ID, scored labels, OCR spans, and change metrics
  versus the previous frame. It is the only routine output of capture.
- **CAP-07** Raw frames stay on device except a frame attached to an
  `ESCALATE_FRAME` decision, taken from a short ring buffer (last 10,
  reversible). Nothing persists past the session except explicit debug
  capture.
- **CAP-08** The digest schema is one contract shared by Swift, the
  Python harness, and the server, so a field recording replays exactly.

## 4. Failure behaviour: classify, then act

- **CAP-09** *Terminal failures* (permission denied, no camera, glasses
  unregistered or Developer Mode off) are never retried in a loop. Capture
  stops, the user is told once, and debug builds offer the TRD-005
  critical-error modal. Only a user action can fix these.
- **CAP-10** *Transient failures* (disconnect, dropped stream, thermal
  throttling) retry with exponential backoff and jitter (~1 s doubling to
  a 30 s ceiling, reset on first good frame), tracked per source so a
  failing glasses source never delays falling back to the phone camera.
- **CAP-11** Backoff is silent: one notice when it starts, one when it
  recovers or gives up. Every retry, reclassification, and give-up is
  logged.

## 5. Experimental glasses microphone

- **CAP-12** Meta marks glasses mic/speech input experimental (not
  shippable in published apps). It shall sit behind a Settings toggle
  whose effective value needs the user's opt-in **and** a build that
  allows it (debug/hackathon builds yes, production no — a stored "on"
  there is inert, not an error). If Meta graduates the API, promotion is
  flipping that one gate plus removing the word "experimental" from the
  labels. While DAT audio is unwired, opting in falls back to the phone
  mic and the UI says so.

## 6. Motion burst

Higher-rate capture on sudden scene change is post-MVP unless the
elevator scenario proves 1 fps too coarse in field testing.

## 7. Tests

Schema round-trip against TRD-004 fixtures; scripted mock walk produces
a stable digest sequence; on-device field run for elevator + street
signs with CAP-03/CAP-10 behaviour visible in the log.
