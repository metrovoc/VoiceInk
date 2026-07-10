# Realtime recording architecture

This document defines the performance contract for recording and realtime
transcription. The contract is intentionally stronger than a collection of
throttles: each high-frequency data path has one owner, bounded memory, and no
dependency on `MainActor` progress.

## Latency boundary

Provider inference time, network round-trip time, and audio-device startup are
measured but are external latency. VoiceInk's own work must stay within these
budgets:

| Local interval | Budget |
| --- | ---: |
| Main-actor frame work | 16.7 ms |
| Recording request to realtime preconnect request | 50 ms |
| Stop request to provider commit request | 50 ms |
| Partial event received to UI publication | 50 ms |
| Oldest streaming audio queue item | 100 ms |

`RealtimePerformanceTrace` records these milestones with the monotonic system
clock. A recording has one trace ID from trigger through delivery, so local
latency cannot be hidden inside a provider measurement.

## Ownership

```text
Core Audio callback
    |-- bounded file-writer pipe ------> audio file
    `-- bounded streaming pipe --------> StreamingTranscriptionCore actor
                                             |-- provider connection/events
                                             |-- ordered audio drain
                                             `-- idempotent commit/final result

Streaming transcript snapshots -------> presentation model
Audio meter latest-value slot ---------> 60 Hz display timeline

Recording control plane (MainActor) ---> visible state and session ownership
Context capture side lane -------------> immutable context snapshot
Post-processing/delivery --------------> persistence and notifications
```

Both Core Audio pipes update one per-recording `RecordingAudioContinuity`
token using atomics only. Hardware seals that token after AUHAL stops and both
pipes drain. A provider may commit concurrently, but its result cannot cross
the service boundary until the hardware seal has been observed and both the
upstream token and downstream queue telemetry have been checked again.
The single-producer/single-consumer rings copy a payload before publishing the
new read index; producer storage is never released while the consumer still
reads it.

The control plane may create, attach, stop, or cancel a session. It does not
send individual audio chunks, consume provider events, rebuild transcript text,
or gate finalization. The bounded preconnect backlog is also drained on a
generic executor before attachment completes, never as a MainActor loop. Those
operations remain owned by the streaming core and its side lanes.

## Non-negotiable invariants

1. Audio delivery never waits for `MainActor`, SwiftUI, context capture,
   SwiftData, or network I/O. Queues are bounded and expose depth, age, and drop
   counters.
2. A queue overflow marks the realtime stream discontinuous. VoiceInk then uses
   the complete recorded file for batch fallback; it never presents a transcript
   produced from known-incomplete audio as final. File-writer overflow or write
   failure is independently exposed and prevents uploading that incomplete file.
3. Stop closes AUHAL immediately, drains the bounded streaming handoff, and
   requests provider finalization as soon as that complete tail crosses the
   streaming barrier. File draining continues independently after the barrier,
   so it never delays provider commit. Repeated stop or cancel requests are
   idempotent and share the same two-phase hardware/finalization task.
   File URL, session, configuration, context capture, continuity token, and
   cancellation state are frozen into that recording generation before any
   await; an older finalizer can neither consume nor clear a newer recording's
   resources.
4. One session owns exactly one provider connection, event consumer, audio
   consumer, and finalization result. Cancellation tears down all four.
   Ordinary committed text is never treated as the acknowledgement for an
   explicit end-of-audio request; every provider maps its wire-level terminal
   event to a distinct `finalized` event. Provider partials use one replaceable
   latest-value slot. Ordered control events use a fixed-capacity ring; if that
   ring ever fills, the relay emits a terminal backlog error and forces WAV
   fallback instead of growing memory or silently losing ordering.
5. Provider events produce revisioned transcript snapshots. Committed segments
   have stable identities; only the current partial segment is replaceable. The
   primary UI path therefore appends or replaces a known range instead of
   diffing and laying out the entire transcript on every event.
6. Metering is a latest-value signal, not an event history. The producer
   overwrites one lock-protected slot and the recorder's display clock samples it
   at 60 Hz. Meter samples never publish through the recorder object.
7. Context capture is described by an immutable plan. An empty plan creates no
   tasks and touches no pasteboard, accessibility, or screen-capture API. Enabled
   capture runs beside recording and cannot delay preconnect or audio startup.
   Accessibility, AppleScript, menu-copy, and OCR are isolated side lanes.
   Optional screen/OCR enrichment uses a non-joining wall-clock timeout: a
   cancellation-ignoring framework call cannot retain or delay the caller.
8. Model availability is refreshed outside the recording hot path and resolved
   by name from a cache. Successful Keychain reads are cached in-process, and
   local model runtimes remain hot across recordings; only explicit lifecycle
   reset or a model transition may release them. Native Whisper loads are
   generation-owned and coalesced, so a short recording joins prewarm instead
   of creating a duplicate context and a stale load can never replace a newer
   model. FluidAudio model/cache state is actor-owned and shared by prewarm,
   realtime, and batch callers without unsynchronized manager mutation.
   A suspension-safe exclusive gate serializes every FluidAudio manager load,
   transcription, and cleanup operation; live FluidAudio capture never starts a
   competing batch runtime on the side lane. Native Whisper batch inference has
   the same whole-operation gate so actor reentrancy cannot interleave language,
   prompt, or inference state on the shared hot context.
   Prewarm loads reusable runtimes directly; it never runs a competing sample
   transcription in the background.
9. The stop path dispatches provider commit before any database work. A minimal
   pending-recording upsert may then run on an independent background context
   while provider and hardware finalization overlap; the control plane never
   waits for it before commit. Final text updates, session metrics,
   notifications, and paste follow-up remain after realtime finalization.
10. Provider construction never fetches SwiftData on `MainActor`. Immutable
    vocabulary snapshots are loaded and coalesced on the preconnect side lane,
    cached per model container, and invalidated only by vocabulary mutations.
    AI-enhancement prompt construction consumes the same snapshot, and each
    enhancement result carries its own request metadata instead of rereading
    mutable global "last request" state after suspension.

## Backpressure and long recordings

Every streaming audio item carries its enqueue time. Queue metrics track total
requested/sent/dropped chunks, current and maximum depth, oldest and maximum
age, and lifecycle timestamps. Queue size alone is not a sufficient health
signal: a shallow but old queue is also over budget.

The Core Audio callback performs no lock acquisition, allocation, executor hop,
or user closure invocation. It only copies into preallocated SPSC storage and
updates atomics. Consumer tasks allocate `Data`, invoke service callbacks, and
perform file I/O after leaving the realtime thread.

The agreement-based FluidAudio path addresses PCM by absolute sample offset in
a fixed-capacity segmented store. Stable punctuation-free speech is committed
at an agreement boundary before the model's 15-second window, retaining a
three-second mutable overlap; a one-hour run-on utterance therefore remains
bounded without silently evicting audio or degrading to quadratic front trims.

Transcript rendering work must scale with the changed suffix, not total
recording length. Meter rendering is constant-memory. No timer or task is
created per audio sample or per partial transcript.

## Release gate

A realtime change is not complete until tests cover ordered draining, audio
before connection, overflow fallback, event storms, concurrent stop/cancel,
final-ack timeout, disconnect timeout, stable transcript revisions, latest-value
meter behavior, empty context plans, and sustained high-volume chunk delivery.
The full unit suite and a Release build must also pass.
