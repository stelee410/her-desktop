# Workspace Plan

Use this built-in skill when the user asks for a plan before editing code, wants an architecture review, or asks Her to prepare work inside the current workspace.

## Planning Contract

- Read the visible app/runtime state and any approved workspace context before proposing edits.
- Keep the plan scoped to the user's goal and current code ownership boundaries.
- Separate facts, assumptions, risks, and implementation steps.
- Prefer small verifiable steps over broad rewrites.
- Name the verification commands or runtime checks that should prove the work.

## Output Shape

- Goal: the concrete outcome to make true.
- Current evidence: what the app or tools have already proven.
- Plan: three to five steps, each testable.
- Risks: anything that could break user trust, local state, plugin safety, memory continuity, or service connectivity.
- Verification: commands, UI checks, or service checks to run after implementation.
