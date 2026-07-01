# Her Desktop

Mac-native AI digital partner shell for the Her ecosystem.

This repository currently contains the first executable SwiftUI foundation:

- Three-pane Her-inspired Mac UI.
- `agentMem` client for memory query/add, relationship signals, and audited post-turn writeback.
- `agentLLMAPI` client for OpenAI-compatible chat completions.
- Orchestrator that composes system prompt + memory context + active work state.
- Plugin manifest registry with built-in workspace planning, AgentLLM media, and vibe-plugin creator capabilities.
- `SOUL.md` / `INFINITI.md` prompt loading inspired by Infiniti Agent, with bundled defaults for fresh workspaces.

The current product/technical architecture diagram lives in [`docs/her-desktop-architecture.md`](docs/her-desktop-architecture.md).

## Configure

Copy the example config and fill local secrets:

```bash
cp Config/her-desktop.local.example.json Config/her-desktop.local.json
```

`Config/her-desktop.local.json` is gitignored. You can also use environment variables:

```bash
export HER_CONFIG_PATH="$HOME/Library/Application Support/Her Desktop/config.json"
export HER_AGENT_LLM_BASE_URL="https://agentllm.linkyun.co"
export HER_AGENT_LLM_API_KEY="sk-..."
export HER_AGENT_LLM_MODEL="linkyun-default"
export HER_AGENT_MEM_BASE_URL="https://agentmem.oyii.ai"
export HER_AGENT_MEM_API_KEY="mem_..."
export HER_AGENT_CODE="her-desktop"
export HER_USER_ID="stelee"
```

`HER_` variables take priority. The loader also accepts service aliases such as
`AGENTLLM_API_KEY`, `AGENTLLM_BASE_URL`, `AGENTMEM_API_KEY`, and
`AGENTMEM_BASE_URL` for local launch scripts. Do not commit real keys; runtime
tool output and artifact manifests redact recognized tokens before display.

For the packaged Mac app, saved configuration defaults to `~/Library/Application Support/Her Desktop/config.json`.
You can also edit the same values from the native macOS Settings window after launch; the main Inspector and Settings share the same save path and immediately re-check AgentLLM health plus chat data-plane readiness, AgentMem identity/query readiness, and plugin runtime health after saving.

## Run

```bash
swift run HerDesktop
```

Her Desktop also installs a native menu bar presence while running. The menu bar entry can reopen the main window, start a fresh conversation, quick-capture a note into the inbox, toggle local dictation and spoken replies, check AgentLLM/AgentMem health, start or stop the local inbox bridge, open Settings, and jump to plugin/workspace directories.

## Test

```bash
swift test
```

## Live Service Smoke Test

After configuring runtime secrets through `Config/her-desktop.local.json`, the
Settings window, or environment variables, use the smoke helper to verify the
same online services the app uses:

```bash
scripts/smoke-services.sh
```

The helper uses the same config precedence as the app: `HER_CONFIG_PATH`, then
the project-local config, then the Application Support config. Environment
variables still win. It checks AgentLLM health, runs one chat completion, reads
AgentMem identity, and performs an AgentMem query scoped by `HER_AGENT_CODE` and
`HER_USER_ID` (`her-desktop` and `stelee` by default). To also verify live
AgentMem writeback, set `HER_SMOKE_WRITE_MEMORY=1`; the script sends a small
smoke-test turn with a deterministic idempotency key.

AgentMem compatibility note: Her Desktop prefers the newer V6 request shape
(`agent_code` + `user_id`) used by the local AgentMem source tree, but the live
service may still expose a key-bound legacy data plane. When AgentMem returns a
422 `extra_forbidden` validation error for scoped fields, the app and smoke
helper retry with the legacy payload instead of treating memory as unavailable.

## Build A Mac App Bundle

```bash
scripts/build-app.sh
open .build/app/HerDesktop.app
```

The bundle script validates that every built-in plugin manifest in `Sources/HerDesktop/Resources/BuiltinPlugins/` is present in the generated `.app`, signs the app with an ad-hoc identity by default, verifies the sealed bundle, and writes a local archive to `.build/dist/HerDesktop.zip`.
Set `HER_CODESIGN_IDENTITY="Developer ID Application: ..."` to use a real signing identity, or `HER_SKIP_CODESIGN=1` for unsigned debugging builds. Public distribution still needs Developer ID signing plus Apple notarization.
The app icon source lives at `Assets/AppIcon-source.png`; the bundle consumes `Assets/AppIcon.icns`.

For public distribution, use the notarization helper after configuring Apple credentials:

```bash
export HER_CODESIGN_IDENTITY="Developer ID Application: Your Team"
export HER_NOTARY_KEYCHAIN_PROFILE="her-desktop-notary"
scripts/notarize-app.sh
```

The helper also accepts App Store Connect API key variables (`HER_NOTARY_KEY`, `HER_NOTARY_KEY_ID`, optional `HER_NOTARY_ISSUER`) or Apple ID variables (`HER_NOTARY_APPLE_ID`, `HER_NOTARY_TEAM_ID`, optional `HER_NOTARY_PASSWORD`). On success it staples the ticket, runs Gatekeeper assessment, and writes `.build/dist/HerDesktop-notarized.zip`.

## Plugin Shape

Plugins live under `.her/plugins/<plugin-id>/plugin.json` by default.
Built-in extensions use the same manifest shape and are bundled from `Sources/HerDesktop/Resources/BuiltinPlugins/*.plugin.json`.
Built-in skill resources, such as `workspace-plan.SKILL.md` and `partner-brief.SKILL.md`, live in `Sources/HerDesktop/Resources/`; skill-backed plugins read them through the same `skillFile` adapter contract as installed plugins. The built-in `workspace.plan` capability is native because it writes the current plan to `.her/workspace/work-plan.json`; `workspace.search`, `workspace.writeTextFile`, and `workspace.replaceText` are also native and approval-bound because they read or edit local workspace content.
Native built-ins that still need AppViewModel state, such as `reflection.snapshot` and `plugin.listDrafts`, also enter through a manifest-declared capability so UI actions, model tool calls, approval policy, audit logs, and future local plugins keep one mental model.
Plugin lifecycle management is also capability-backed: `plugin.stagePackage` validates pasted/imported PluginPackage JSON and stages it for review, `plugin.listDrafts` lists staged generated drafts without side effects, `plugin.listInstalled` lists installed `local.*` packages with follow-up arguments, `plugin.inspect` summarizes a local package before update/export/removal, `plugin.installDraft` installs already staged generated drafts after approval, `plugin.discardDraft` discards staged drafts after approval, `plugin.install` installs generated packages after approval, `plugin.export` writes installed `local.*` packages to the workspace after approval, and `plugin.remove` removes installed `local.*` plugins after approval.
Prompt defaults are bundled from `Sources/HerDesktop/Resources/SOUL.md` and `Sources/HerDesktop/Resources/INFINITI.md`; workspace-local `SOUL.md`, `AGENTS.md`, `AGENT.md`, `INFINITI.md`, `CLAUDE.md`, or `.claude/CLAUDE.md` still override them.
The system prompt follows Infiniti Agent's memory layering discipline: current chat, verified tool results, app state, AgentMem retrieval, companion profile, Dream Context, and plugin lifecycle events are separate evidence layers. Retrieved memory is relevant background, not a complete database dump; missing retrieval should not be treated as proof that a user preference, plugin state, or prior decision does not exist.
The registry discovers bundled `*.plugin.json` resources dynamically, so adding a new built-in extension should not require a Swift registration list.

When adding a new built-in extension, keep it plugin-first:

- Add or update a manifest under `Sources/HerDesktop/Resources/BuiltinPlugins/`.
- Give every capability an explicit adapter and input schema.
- Put bundled skill instructions in `Sources/HerDesktop/Resources/*.SKILL.md`.
- Keep secrets in runtime config placeholders, never in plugin files.
- Run `swift test --filter BuiltInPluginContractTests` before shipping.

```json
{
  "id": "local.example",
  "name": "Example",
  "version": "0.1.0",
  "description": "A small extension.",
  "capabilities": [
    {
      "id": "example.run",
      "title": "Run example",
      "kind": "skill",
      "invocation": "example.run",
      "requiresApproval": true
    }
  ]
}
```

Vibe-coded installs use a package shape so the assistant can generate both a manifest and supporting files:

```json
{
  "manifest": {
    "id": "local.example",
    "name": "Example",
    "version": "0.1.0",
    "description": "A small extension.",
    "capabilities": []
  },
  "files": [
    {
      "path": "SKILL.md",
      "content": "# Example\n\nInstructions for the skill."
    }
  ]
}
```

Plugin file paths must be relative and cannot contain `..`; installation is gated by the approval queue when a capability declares `requiresApproval`.
Plugin adapters can use safe runtime config placeholders such as `{{agent_llm_base_url}}`, `{{agent_llm_api_key}}`, `{{agent_llm_model}}`, `{{agent_mem_base_url}}`, `{{agent_mem_api_key}}`, `{{agent_code}}`, and `{{user_id}}`; Her Desktop renders them at execution time so generated packages do not store real secrets.
Web service `bodyTemplate` values can use `{{json:field}}` or `{{json:field|default}}` to produce escaped JSON literals for user-provided text.
MCP adapters call only local HTTP JSON-RPC bridges. For standard MCP tool calls, set `methodName` to `tools/call` and `toolName` to the exact bridge tool; Her Desktop sends `params` as `{"name": toolName, "arguments": {...capability arguments...}}`.
The Vibe Plugin Composer can call `tools/list` on a local MCP bridge, show discovered tools and input fields, fill `methodName=tools/call` plus `toolName` from a selected tool, directly draft a local MCP plugin from a discovered tool, and carry supported discovered schema fields into the generated plugin `inputSchema`.
Generated `SKILL.md` and `README.md` files include the adapter contract and input fields so exported plugin packages remain reviewable and reusable. Plugin drafts created by model tool calls through `plugin.draft` are documented, staged, persisted, and shown with the same follow-up install/discard arguments as drafts created from the Vibe Plugin Composer.
When AgentLLM returns an invalid generated package, the AI composer gives the model one validation-feedback repair pass before surfacing the error, so common manifest/schema omissions can be corrected without weakening the same validator and approval gates.
Generated and imported plugin drafts also receive a structured permission summary during review. The install sheet shows whether a package can read packaged skill files, call network services, reach a local MCP bridge, run a fixed command, read local files or attachments, speak, notify, write memory, or install/update another plugin, and whether each action requires approval.
Plugin capabilities may declare an `inputSchema` object. The Plugin Library run dialog uses simple object schemas to render structured fields for strings, enums, numbers, integers, and booleans, then passes those arguments directly to the capability executor.
Web service JSON responses that include image generation fields such as `data[].url` or `data[].b64_json` are persisted under `.her/workspace/webservice-artifacts/` with an artifact manifest, response JSON, and decoded local image files when base64 media is present. Tool results reference those paths instead of flooding the conversation with raw media payloads. Conversation tool messages show artifact chips for referenced manifests, and the Inspector's Artifacts card lists recent manifests, shows local image previews when available, and opens the manifest, response, local image, or remote media URL.

Conversation continuity is rooted in `.her/session.json`, which stores the local transcript and a stable `session_id` used for AgentMem query/add calls.
Work continuity is rooted in `.her/workspace/work-plan.json`, which stores the current goal, ordered steps, risks, and verification checks. The built-in `workspace.plan` capability can update it from model tool calls or the Plugin Library; Projects shows it as Current Plan, Inspector uses it for Active Plan, Agent Loop uses it for the Plan phase, and Active Work State injects it as state data, not trusted instructions.
AgentMem requests are scoped by both `user_id` and `agent_code`: query/add send them in the JSON body, and relationship refresh reads `/v1/users/{user_id}/relationship?agent_code=...`.
The Memory workspace can generate a local reflection snapshot at `.her/dreams/prompt-context.json`; the same write path is exposed as the approved `reflection.snapshot` built-in plugin capability. Future turns load it as Dream Context so long-horizon objectives, recent insights, behavior guidance, open threads, and cautions survive without giving that compressed context instruction authority.
User-attached files are copied under `.her/attachments/` and referenced from the transcript; UTF-8 text and selectable-text PDF attachments include a bounded preview in the model context, and image attachments include lightweight visual metadata such as dimensions, color model, alpha, and DPI when available. Video, audio, and other files are represented with reliable metadata until a media/plugin processor is invoked.
Spoken replies can be enabled from the toolbar or configuration panel; this uses local macOS speech synthesis. The composer mic button uses local macOS speech recognition to fill draft text and does not auto-send. Explicit speech tool calls are also exposed as the approved `native.speak` plugin capability.
Generated plugin drafts awaiting review are persisted under `.her/plugin-drafts/`, so vibe-coded extension packages survive app restarts until installed or discarded.
Installed local plugins can be exported back to PluginPackage JSON under `.her/workspace/plugin-exports/` for backup, review, or reuse.
Pasted or imported PluginPackage JSON is staged into the same generated-drafts review queue before installation, either from the UI composer or through the `plugin.stagePackage` capability.
Successful plugin installs return a quick-start summary with each capability's function name, native form inputs, adapter type, and approval requirement, so vibe-coded extensions are immediately usable from the Plugin Library or model tool calls. When a draft is already staged, conversation can continue with `plugin.listDrafts`, then `plugin.installDraft` or `plugin.discardDraft` by plugin id and draft id instead of asking the model to reconstruct package JSON; draft creation/import/list messages include those exact follow-up arguments. Installed local plugins can be listed through `plugin.listInstalled`, inspected through `plugin.inspect`, then backed up or reused through the approved `plugin.export` capability.
Plugin lifecycle events are also written to `.her/logs/plugin-events.jsonl` and shown in the Inspector's Plugin Timeline, giving vibe-coded extensions an observable trail from draft to install, update, export, discard, or removal. Installs performed through the approved `plugin.install` capability enter the same timeline and clear matching generated drafts; removals performed through the approved `plugin.remove` capability enter the same timeline and keep built-in plugins protected.

## Local Inbox Bridge

The Inspector can start a local HTTP inbox bridge at `http://127.0.0.1:8766/inbox`.
It is off by default. When enabled, external tools can POST JSON and Her will capture the message as an `inbox.capture` plugin event, append it to `.her/inbox/events.jsonl`, and show it in Interaction Events.
For local thoughts or tasks, use `Shift+Command+I` or the menu bar's Quick Capture action. It writes through the same inbox capture path, including interaction history, audit trail, `.her/inbox/events.jsonl` persistence, and the next conversation's Active Work State. Inbox text is injected as state data, not as trusted instructions.

```bash
curl -X POST http://127.0.0.1:8766/inbox \
  -H "Content-Type: application/json" \
  -d '{"source":"oyii","sender":"Leo","text":"Review this thread","attachment_paths":["/Users/stelee/Desktop/screenshot.png"]}'
```

Capturing an inbox message does not send a reply to the external service. Outbound replies need a separate approved sender capability.
`attachment_paths`, `attachments`, or `files` may contain local file paths from the bridge host; Her Desktop imports readable files into `.her/attachments/`, attaches them to the inbox event, and reports import failures without dropping the text message. It does not download remote URLs from inbox payloads.

Executable adapters currently include:

- `skill`: reads the installed package's `SKILL.md` through safe relative paths.
- bundled `skill`: reads bundled resource files declared by built-in plugin manifests, so new built-in extensions can be added without hard-coding Swift executors.
- `webservice`: calls HTTPS endpoints, or local HTTP endpoints, with GET/POST contracts. Built-in AgentLLM Media uses this path to call the configured image generation endpoint after approval.
- `mcp`: posts JSON-RPC 2.0 requests to a local HTTP bridge on `localhost`, `127.0.0.1`, or `::1`; `tools/call` adapters should declare `toolName` so capability arguments are wrapped as MCP tool arguments.
- `mcp.discover`: built-in local discovery that posts `tools/list` to a bridge and returns tool names, descriptions, and input schema summaries for vibe-coded plugin creation.
- `command`: runs a fixed executable with fixed argument templates, no shell, a bounded timeout, and required approval.
- `native`: supports built-in macOS actions such as notifications, approved workspace search and text artifact edits, approved UTF-8 text-file reads, approved attachment inspection/PDF extraction/image metadata, approved text-to-speech playback, inbox capture with optional local attachment import, AgentMem read/write, and approved reflection snapshots.
