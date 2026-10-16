# Stream Event Contract Changes Need Dual-Tolerance + Deploy-Order Discipline

DentalWave patient-summary streaming (refactor 2026-10): when changing an ActionCable event contract, the frontend must tolerate BOTH the old and new backend, because deploy order is not guaranteed.

Key rules discovered the hard way:

1. **Discriminate old-vs-new contracts by KEY PRESENCE, not length.** The broadcaster's `.compact` drops `nil` but KEEPS `[]` — so the old backend's `completed` could legitimately carry `ai_tags: []`. A `payload.ai_tags?.length` check misroutes that payload to the new-contract branch (spurious banner + lost emit). Use `payload.ai_tags !== undefined && payload.ai_tags !== null` (or `Array.isArray`).
2. **Intermediate progress events can strand old clients.** The new tagging job initially relayed the tagger's `tagging` event AFTER `completed` — old frontends (with banner-on-`tagging` but no `tags_ready` handler) got a non-dismissible banner. Fix: the background job relays NOTHING except its terminal event. Never broadcast intermediate events from a job unless every known client version handles every event it can emit.
3. **Background-job terminal events must be unconditional.** A job that ends state on the client (e.g. clearing a banner) should broadcast its terminal event even on failure (regex-fallback tags), or pair with a client-side safety timeout + refetch. We used both — frontend 30s safety timer with a recovery refetch is the umbrella that covers every stranded-banner edge (missing records skip, retry windows).
4. **Guard stale async results by patient id** at the top of every fetch `.then` (`data?.patient_id !== props.patientId`) — same pattern as the cable `received` filter, which is load-bearing because there are TWO parallel cable subscribers (card + trigger).
5. Missing-records in a background job: warn + skip WITHOUT broadcasting is fine when the client's safety timeout absorbs it, and the tags would be meaningless anyway.