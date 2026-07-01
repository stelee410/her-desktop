# Her Desktop Architecture V2

这版图的目标是把 Her Desktop 设计成一个可扩展的 Mac 原生 AI 数字合伙人：桌面端负责体验、状态、权限和编排；AgentLLMAPI 负责模型与多模态能力；AgentMem 负责长期记忆与关系状态；插件运行时负责把技能、MCP、Web 服务和本机能力安全接入。

```mermaid
flowchart TB
    User["User"]

    subgraph Surfaces["Interaction Surfaces"]
        Mac["Her Desktop\nSwiftUI / AppKit"]
        Voice["Voice / Realtime\nASR + TTS"]
        Files["Files / Clipboard\nattachments"]
        External["Future Connectors\nOyii / Discord / WeChat / Browser"]
    end

    subgraph App["Her Desktop App Boundary"]
        Shell["Native Experience Shell\nconversation / timeline / inspector / avatar"]
        Session["Session Store\n.her/session.json"]
        Runtime["Interaction Runtime\nturn state / interruption / active tasks"]
        Prompt["Context Composer\npersona + project docs + recent turns + memory"]
        Orchestrator["Agent Orchestrator\nplanning / tool intent / result synthesis"]
        Policy["Policy + Approval Gate\npermissions / side effects / secrets boundary"]
        Router["Capability Router\nplugin registry + tool catalog + executor"]
        LocalState["Local Workspace\n.her/workspace / logs / generated drafts"]
    end

    subgraph Extensions["Extension Runtime"]
        Builtins["Built-In Capabilities\nworkspace / plugin creator / native macOS"]
        Plugins["Installed Plugins\nplugin.json + SKILL.md + assets"]
        Skills["Skill Adapter\nprompted workflows"]
        MCP["MCP Adapter\nexternal tool servers"]
        WebSvc["WebService Adapter\nHTTPS / localhost APIs"]
        Native["Native Adapter\nnotifications / file reads / future calendar"]
        Command["Command Adapter\nfixed executable + approval"]
    end

    subgraph LLM["AgentLLMAPI Project"]
        Chat["Chat / Responses API"]
        AgentRoute["AgentRoute\nspecialist routing"]
        MultiModal["Multimodal\nimage / audio / video / embeddings"]
        Realtime["Realtime Bridge\nstreaming voice"]
        ModelRouter["Model Router\nfallback / circuit breaker / usage"]
    end

    subgraph Mem["AgentMem Project"]
        Query["Memory Query\nretrieval context"]
        Add["Memory Add\nturn persistence"]
        Profile["Profile + Relationship\naffection / preferences"]
        Consolidate["Dream / Insight\nbackground consolidation"]
        Store["Memory Stores\nfacts / graph / window / relationship"]
    end

    subgraph Ops["Security / Observability"]
        Config["Local Config\nAPI keys / endpoints / model"]
        Health["Health Checks\nLLM / Mem / plugin runtime"]
        Audit["Audit Trail\napprovals / tool calls / errors"]
    end

    User --> Mac
    User --> Voice
    User --> Files
    External --> Shell
    Mac --> Shell
    Voice --> Runtime
    Files --> Runtime

    Shell --> Runtime
    Session --> Prompt
    Runtime --> Prompt
    LocalState --> Prompt
    Prompt --> Orchestrator
    Orchestrator --> Shell
    Orchestrator --> Policy
    Policy --> Router
    Router --> Builtins
    Router --> Plugins
    Plugins --> Skills
    Plugins --> MCP
    Plugins --> WebSvc
    Plugins --> Native
    Plugins --> Command

    Orchestrator -->|"reasoning request"| Chat
    Orchestrator -->|"specialist task"| AgentRoute
    Orchestrator -->|"media task"| MultiModal
    Runtime -->|"voice stream"| Realtime
    Chat --> ModelRouter
    AgentRoute --> ModelRouter
    MultiModal --> ModelRouter
    Realtime --> ModelRouter
    ModelRouter --> Orchestrator

    Prompt -->|"before turn"| Query
    Orchestrator -->|"after turn"| Add
    Query --> Store
    Add --> Store
    Profile --> Store
    Consolidate --> Store
    Store --> Query
    Store --> Profile
    Add -. "idle consolidation" .-> Consolidate
    Profile --> Prompt

    Config --> Prompt
    Config --> Health
    Health --> Shell
    Policy --> Audit
    Router --> Audit
    Orchestrator --> Session
    Router --> LocalState

    classDef surface fill:#fff7f1,stroke:#d8967d,color:#2d1b16
    classDef app fill:#fffdfa,stroke:#e66f61,color:#2a1c18
    classDef ext fill:#fff8dc,stroke:#d3a733,color:#2f2609
    classDef llm fill:#f5f9ff,stroke:#6d91bd,color:#14243a
    classDef mem fill:#f5fff7,stroke:#69a87b,color:#14301d
    classDef ops fill:#f7f7f7,stroke:#8d8d8d,color:#222222

    class User,Mac,Voice,Files,External surface
    class Shell,Session,Runtime,Prompt,Orchestrator,Policy,Router,LocalState app
    class Builtins,Plugins,Skills,MCP,WebSvc,Native,Command ext
    class Chat,AgentRoute,MultiModal,Realtime,ModelRouter llm
    class Query,Add,Profile,Consolidate,Store mem
    class Config,Health,Audit ops
```

## Key Boundaries

- Her Desktop 不直接拥有大模型供应链，也不直接拥有长期记忆数据库；它拥有用户体验、运行时状态、权限边界、上下文组装和工具编排。
- AgentLLMAPI 是模型能力网关，负责 Chat、AgentRoute、多模态、Realtime、fallback、circuit breaker 和用量治理。
- AgentMem 是人格连续性和关系连续性的系统，负责 query/add/profile/consolidation，而不是普通本地缓存。
- 插件运行时不是随意执行代码的后门；它应以 `plugin.json` 为能力契约，以审批队列和 adapter sandbox 为执行边界；内置扩展也从 bundled plugin manifests 加载。
- MCP、命令行、本机系统能力要比普通 skill/webservice 更高风险，默认需要明确权限模型和审计记录；当前 MCP 只允许通过本机 HTTP JSON-RPC bridge 执行，command 只允许运行固定 executable 和固定参数模板。

## Main Turn Flow

```mermaid
sequenceDiagram
    participant U as User
    participant UI as Her Desktop UI
    participant H as Orchestrator
    participant M as AgentMem
    participant L as AgentLLMAPI
    participant P as Policy Gate
    participant C as Capability Runtime

    U->>UI: text / voice / file / intent
    UI->>H: normalized interaction event
    H->>M: query(session_id, query, retrieval_policy)
    M-->>H: memory context + profile signals
    H->>L: composed prompt + recent turns + available tools
    L-->>H: assistant response or structured tool call
    H->>P: check capability risk and required approval
    alt approval required
        P-->>UI: ask user to approve
        U->>UI: approve or reject
    end
    P->>C: execute approved/no-risk capability
    C-->>H: structured result
    H->>L: result synthesis request
    L-->>H: final user-facing answer
    H->>M: add(turn summary, metadata)
    H-->>UI: transcript + task timeline + state updates
```

## Extension Creation Flow

```mermaid
flowchart LR
    Ask["User describes desired extension"] --> Draft["Vibe Plugin Creator\nplugin.draft"]
    Draft --> Review["Generated Draft Queue\nmanifest + skill + adapter config"]
    Review --> Approve["User reviews and installs"]
    Approve --> Registry["PluginRegistry\nsafe write into plugin dir"]
    Registry --> Catalog["Tool Catalog\nfunction schemas exposed to AgentLLMAPI"]
    Catalog --> Use["Assistant can call capability\nthrough approval + executor"]
    Use --> Audit["Audit trail + health state"]
```

## Design Critique Encoded In This Diagram

- 把 `Interactive` 拆成 `Runtime`、`Context Composer`、`Orchestrator`、`Policy Gate`，否则后面语音、工具、记忆和 UI 状态会全部缠在一起。
- `AgentLLMAPI` 和 `AgentMem` 不应该像普通工具一样挂在同一层；它们是平台服务，分别承载模型能力和人格连续性。
- 插件系统要从第一天就有 manifest、adapter、approval、audit 四个概念，不然扩展性会变成安全债。
- 多入口连接器可以后置，但内部事件模型要先抽象好：所有入口都变成 normalized interaction event。
- “陪伴”和“工作伙伴”不是两个模式，而是同一个 turn runtime 里不同上下文权重、记忆策略和工具风险策略的组合。
