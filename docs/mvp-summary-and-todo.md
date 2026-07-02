# Her Desktop MVP Summary And TODO

Date: 2026-07-02

## Current Decision

Her Desktop has reached a functional MVP loop. The app is not a polished public
release yet, but the core product loop is now closed enough to stop expanding
architecture and begin real usage testing.

From this point, new work should be limited to:

- Fixing blockers found during hands-on testing.
- Improving packaging, signing, and distribution.
- Tightening the existing UI and plugin flows.
- Adding tests only where they protect already implemented behavior.

It should not continue growing new architecture until the current MVP has been
used in real daily sessions.

## Closed MVP Loop

The MVP loop is considered closed because the app can now:

- Launch as a native macOS SwiftUI app with a persistent local session.
- Save runtime configuration to the correct writable Application Support path.
- Start a conversation when only AgentLLM is configured.
- Treat AgentMem, plugins, voice, inbox, and diagnostics as optional
  enhancements instead of first-run blockers.
- Give conversational recovery guidance when the API key is missing, a service
  is unavailable, auth fails, or optional plugins are not ready.
- Compose model context from the current chat, runtime state, tool evidence,
  workspace plan, prompt documents, AgentMem signals, companion profile, and
  Dream Context.
- Use AgentLLM through an OpenAI-compatible chat client.
- Use AgentMem V7 through Memory-Key scoped calls without requiring `user_id` or
  `agent_code` in query/add data-plane requests.
- Load built-in plugins dynamically from bundled manifests.
- Install, update, export, inspect, remove, and run local plugin packages through
  the same approval-gated runtime.
- Generate reviewable vibe-coded plugin drafts for skills, web services, local
  command adapters, and local MCP bridges.
- Persist generated plugin drafts, plugin lifecycle events, audit events,
  diagnostics, workspace artifacts, attachments, inbox events, and work plans.
- Build a signed local `.app` bundle and ZIP archive.
- Verify the app locally and in GitHub Actions using the same one-command
  verifier.

## Evidence

Latest verified baseline:

- Commit: `2c7db6d Document MVP status and TODOs`
- Branch: `main`
- GitHub Actions: latest five `main` CI runs succeeded as of 2026-07-02.
- Local verification passed with `scripts/verify-local.sh`.
- Release-candidate local verification passed with
  `HER_VERIFY_APP_LAUNCH=1 scripts/verify-local.sh`.
- Live service smoke passed with configured local secrets using
  `scripts/smoke-services.sh`.

No real API keys or Memory keys are committed. Secret scanning is part of the
local verifier and CI gate.

## How To Test The MVP Now

Build and launch the packaged app:

```bash
scripts/build-app.sh
open .build/app/HerDesktop.app
```

Run the local development gate:

```bash
scripts/verify-local.sh
```

Run the release-candidate local gate:

```bash
HER_VERIFY_APP_LAUNCH=1 scripts/verify-local.sh
```

Run live service smoke after configuring local secrets:

```bash
scripts/smoke-services.sh
```

In the app, the first hands-on acceptance pass should test:

- Enter or confirm the AgentLLM API key in Settings.
- Start a normal conversation.
- Ask the assistant to check product readiness.
- Export diagnostics.
- Generate a tiny local plugin draft.
- Review and approve installation.
- Run the newly installed capability.
- Restart the app and confirm the session, config, and plugin draft/install
  state persist.

## Known Boundaries

These are not blockers for MVP closure, but they are not finished product work:

- The app is not yet notarized for public macOS distribution.
- There is no DMG or auto-update channel yet.
- Long multi-hour daily companion sessions have not been validated by the user.
- Complex third-party MCP bridges need real-world bridge examples.
- The UI needs a focused polish and accessibility pass after real use.
- Voice, dictation, inbox, and local native actions exist, but they are not the
  main MVP acceptance path.
- There is no full automated UI test suite; current coverage is unit tests,
  bundle validation, launch smoke, secret scanning, and live service smoke.

## TODO

### P0: Before Calling It A Usable Alpha

- Run one complete hands-on session from a clean user config:
  configure AgentLLM, chat, export diagnostics, generate a plugin, approve it,
  run it, restart the app, and confirm persistence.
- Fix any blocker found in that hands-on pass before adding new capabilities.
- Confirm the Settings save path on the packaged app, not only `swift run`.
- Confirm the missing-key and service-down flows feel conversational rather
  than menu-driven.
- Capture one real plugin generation case that the user actually wants to use
  daily, then keep or remove complexity based on that evidence.

### P1: Packaging And Product Quality

- Create a Developer ID signed and notarized build.
- Add a DMG or installer flow.
- Add a short release checklist that points to the exact verification commands.
- Do a focused UI polish pass after the first real usage session.
- Add accessibility checks for keyboard navigation, contrast, labels, and
  dynamic text.
- Add one or two UI smoke tests around launch, settings save, and plugin review
  if the current manual path proves repetitive.
- Validate one real local MCP bridge end to end.
- Validate one real web-service plugin end to end, including artifact handling.

### P2: Later Expansion

- Add auto-update.
- Move long-lived secrets to Keychain while preserving the current config
  ergonomics for development.
- Add a richer built-in plugin gallery only after the first local plugin use
  cases stabilize.
- Improve voice and audio workflows if they become part of daily usage.
- Add multi-workspace or multi-profile behavior if the single-user memory model
  becomes limiting.
- Add deeper long-term memory evaluation based on real AgentMem writeback
  quality.
- Add richer media generation and attachment processors after core conversation
  and plugin usage are stable.

## Stop Rule

For this phase, stop adding features when the functional loop above stays green.
The next useful work is user testing, blocker fixes, and release packaging, not
another architecture layer.
