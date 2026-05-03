---
name: Mirror auto-memory into the openbirds repo on every chunk
description: User wants ~/.claude/.../memory/*.md mirrored into docs/memory/ in the repo and committed alongside the work, every time a chunk lands.
type: feedback
originSessionId: 96f7f6ca-4d02-4a6f-bbf7-077f264f7c89
---
When finishing a chunk of work in openbirds: copy every `*.md` from `~/.claude/projects/-Users-sweater-Github-openbirds/memory/` into `docs/memory/` in the repo, then include them in the same commit as the code changes. Push afterwards if the user requested it (they did, on 2026-05-03).

**Why:** the user wants the memory accumulated across sessions to be version-controlled and shareable, not stuck in a per-machine `~/.claude` directory that nobody else can see and that vanishes if the machine dies. Treating `docs/memory/` as the canonical mirror keeps both Claude and humans honest about what assumptions are baked in.

**How to apply:**
- After each meaningful chunk of work, before committing, run `cp ~/.claude/projects/-Users-sweater-Github-openbirds/memory/*.md docs/memory/`.
- Stage the entire `docs/memory/` along with the code changes — they belong in the same commit so the rationale lands with the change that prompted it.
- Update `docs/memory/MEMORY.md` to mirror `~/.claude/.../memory/MEMORY.md` (it gets overwritten by the cp, so this is automatic).
- The `~/.claude` copy stays authoritative for runtime use; the repo copy is the durable mirror.
