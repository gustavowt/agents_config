# Agent Removal / Addition Sync Points

A canonical agent lives in four places; touching any subset leaves the repo inconsistent and can break the installer:

1. `agents/<name>.md` — the canonical definition (delete or create).
2. `opencode.json` — `agent.<name>.model` must be a non-empty, `ollama/`-prefixed string matching a key in `provider.ollama.models` (enforced by `pi_agent_models` / `pi_ollama_models` in `bin/agents_config`; missing entry or wrong prefix fails Pi install).
3. `bin/agents_config` — `GEMINI_AGENT_MODELS` hash (stale keys are silent dead weight; missing keys fall back to `gemini-2.5-flash`).
4. `bin/agents_config_test.rb` — the gemini build test's `pro_agents` / `flash_agents` arrays assert generated files exist; stale names fail the suite.

Verification: `ruby bin/agents_config_test.rb` catches stale names (3 of 4 points) but NOT the opencode.json model invariants unless Pi paths are exercised — run the installer or check `pi_ollama_models` logic when changing models. `grep -rn "<name>" --exclude-dir=.git .` must come back empty after a removal.

Gotcha (2026-10-15): model values without the `ollama/` prefix pass JSON validation but fail Pi install — the installer splits on `/` and requires prefix `ollama`.