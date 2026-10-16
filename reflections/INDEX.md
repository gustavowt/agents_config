# Reflections Index

- [stream-event-contract-dual-tolerance.md](stream-event-contract-dual-tolerance.md) — ActionCable event contract changes: key-presence discrimination, no job intermediate events, unconditional terminal events + client safety timeout.
- [ai-stream-buffering-pitfalls.md](ai-stream-buffering-pitfalls.md) — StreamBuffers: whitespace flush regex defeats buffering; no content_full per delta; frontend-side tag masking; kwargs with legacy defaults for shared buffers.
- [agent-removal-sync-points.md](agent-removal-sync-points.md) — A canonical agent lives in 4 places (agents/, opencode.json, GEMINI_AGENT_MODELS, gemini test arrays); `ollama/` prefix required or Pi install fails.