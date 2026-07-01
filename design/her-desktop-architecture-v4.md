# Her Desktop Architecture V4

这版架构把 Her Desktop 设计成一个 Mac 原生的 AI 数字合伙人：体验在本机，思考走 AgentLLMAPI，长期关系和事实走 AgentMem，工作能力通过可审计的插件平台扩展。Infiniti Agent 不作为后端依赖强行塞进来，而是作为人格、项目级 agent layout、skills、LiveUI/voice 经验的兼容与迁移来源。

## Architecture Map

```mermaid
flowchart LR
    User["User\ntext / voice / files / approvals"]

    subgraph Entry["Interaction Surfaces"]
        MacUI["Mac Native SwiftUI\nconversation / inspector / sidebar"]
        Voice["Local Voice I/O\nspeech recognition / TTS"]
        Files["File Intake\nattachments / previews / artifacts"]
        FutureInbox["Future Inboxes\nOyii / WeChat / Discord / browser"]
    end

    subgraph Her["Her Desktop Core"]
        EventBus["Interaction Event Bus\nnormalize user, voice, file, inbox events"]
        Turn["Turn Runtime\nstate machine / cancellation / task timeline"]
        Context["Context Composer\nSOUL + INFINITI + session + active work + memory"]
        Orchestrator["Agent Orchestrator\nbounded tool loop / synthesis / follow-up"]
        Policy["Policy + Approval Gate\nrisk class / permission / secret boundary"]
        Audit["Audit + Observability\nhealth checks / traces / capability history"]
        LocalStore["Local Workspace\n.her/session, attachments, plugins, drafts, audit"]
    end

    subgraph LLM["AgentLLMAPI Service"]
        Gateway["OpenAI-Compatible Gateway\nchat / responses / images / video / embeddings"]
        Router["Agent Router\nmodel aliases / specialist routes / smart mode"]
        Reliability["Reliability Layer\nfallback / circuit breaker / probes / trust score"]
        Billing["Tenant + Usage Layer\nkeys / ACL / quotas / cost records"]
    end

    subgraph Mem["AgentMem Service"]
        MemQuery["Pre-Turn Query\nfacts / graph / sliding window / relationship"]
        MemAdd["Post-Turn Add\nasync extraction / idempotent writeback"]
        Relationship["Companion Memory\nprofile / affection / preferences / intent"]
        Dream["Background Dream\nconsolidation / conflict / reflection"]
        Stores["Memory Stores\nfacts / graph / windows / relationship state"]
    end

    subgraph Ext["Extension Platform"]
        Registry["Plugin Registry\nbundled + user .her/plugins"]
        Review["Plugin Review\nvibe draft / import / install approval"]
        Catalog["Tool Catalog\nfunction schemas exposed to model"]
        Executor["Capability Executor\nadapter isolation / structured result"]
        Skill["Skill Adapter\nSKILL.md workflows"]
        Web["WebService Adapter\nHTTP APIs"]
        MCP["MCP Adapter\nlocal JSON-RPC bridge"]
        Command["Command Adapter\nfixed executable, fixed args"]
        Native["Native Adapter\nnotification / file read / speech / inspect"]
    end

    subgraph Infiniti["Infiniti-Agent Compatibility"]
        Soul["SOUL.md / INFINITI.md\npersonality and project instructions"]
        Layout["Project Agent Layout\n.agent archive / .infiniti-agent"]
        LegacySkills["Existing Skills\nportable workflow knowledge"]
        LiveLessons["LiveUI / Voice Lessons\navatar, TTS, ASR patterns"]
    end

    subgraph External["External Work World"]
        LocalApps["macOS Apps\nCalendar / Mail / Files / Shortcuts"]
        DevTools["Developer Tools\nCodex / git / terminal / IDE"]
        WebApis["SaaS + Web APIs\nsearch / docs / business systems"]
        Devices["Devices\nphone / tablet / wearables"]
    end

    User --> MacUI
    User --> Voice
    User --> Files
    FutureInbox --> EventBus
    MacUI --> EventBus
    Voice --> EventBus
    Files --> EventBus

    EventBus --> Turn
    Turn --> LocalStore
    LocalStore --> Context
    Soul --> Context
    Layout --> LocalStore
    LegacySkills --> Registry
    LiveLessons --> Voice

    Turn --> MemQuery
    MemQuery --> Stores
    Stores --> Relationship
    Relationship --> Context
    MemQuery --> Context
    Context --> Orchestrator

    Orchestrator --> Gateway
    Gateway --> Router
    Router --> Reliability
    Gateway --> Billing
    Reliability --> Gateway
    Gateway --> Orchestrator

    Orchestrator --> Policy
    Policy --> Catalog
    Registry --> Catalog
    Review --> Registry
    Catalog --> Executor
    Executor --> Skill
    Executor --> Web
    Executor --> MCP
    Executor --> Command
    Executor --> Native
    Skill --> DevTools
    Web --> WebApis
    MCP --> LocalApps
    Command --> DevTools
    Native --> LocalApps
    Native --> Devices
    Executor --> Orchestrator

    Orchestrator --> MemAdd
    MemAdd --> Stores
    MemAdd -. "async" .-> Dream
    Dream --> Stores

    Policy --> Audit
    Executor --> Audit
    Gateway --> Audit
    MemQuery --> Audit
    MemAdd --> Audit
    Audit --> MacUI
    Orchestrator --> MacUI

    classDef entry fill:#fff4ee,stroke:#df826d,color:#271613
    classDef core fill:#fffdfa,stroke:#cf5f51,color:#241412
    classDef llm fill:#eef6ff,stroke:#5d87b5,color:#10243d
    classDef mem fill:#f0fff4,stroke:#5b9c71,color:#102b1a
    classDef ext fill:#fff9dd,stroke:#b8962d,color:#2d2408
    classDef inf fill:#f7f1ff,stroke:#8d72b8,color:#241337
    classDef external fill:#f6f6f6,stroke:#888,color:#222

    class MacUI,Voice,Files,FutureInbox entry
    class EventBus,Turn,Context,Orchestrator,Policy,Audit,LocalStore core
    class Gateway,Router,Reliability,Billing llm
    class MemQuery,MemAdd,Relationship,Dream,Stores mem
    class Registry,Review,Catalog,Executor,Skill,Web,MCP,Command,Native ext
    class Soul,Layout,LegacySkills,LiveLessons inf
    class LocalApps,DevTools,WebApis,Devices external
```

## Turn Loop

```mermaid
sequenceDiagram
    participant U as User
    participant UI as Her Desktop UI
    participant T as Turn Runtime
    participant M as AgentMem
    participant O as Orchestrator
    participant L as AgentLLMAPI
    participant P as Policy Gate
    participant X as Extension Runtime
    participant A as Audit

    U->>UI: message / voice / file / approval
    UI->>T: normalized interaction event
    T->>M: query(user_id, agent_code, session_id, intent)
    M-->>T: injected_context + relationship/profile signals
    T->>O: prompt bundle + available capabilities + local state
    O->>L: chat or responses request with tool schemas
    L-->>O: assistant response or tool calls
    O->>P: classify requested capability risk
    alt approval required
        P-->>UI: approval card
        U->>UI: approve / reject
        UI->>P: decision
    end
    P->>X: execute approved capability
    X-->>O: structured result envelope
    O->>L: synthesize final answer from result
    L-->>O: final message
    O->>M: add(audited turn summary, emotions, facts, relationships)
    O->>A: turn trace + tool result + memory writeback status
    O-->>UI: transcript / timeline / spoken reply
```

## Extension Contract

```mermaid
flowchart TB
    Request["User asks for a new capability\nnatural language"]
    Draft["Vibe Plugin Composer\nLLM-assisted package draft"]
    Package["PluginPackage\nmanifest + bounded files"]
    Review["Human Review\npermissions, paths, endpoints, commands"]
    Install["Install to .her/plugins\nversioned local package"]
    Registry["Plugin Registry\nload + validate"]
    ToolSchema["Tool Catalog\nOpenAI-compatible schema"]
    Runtime["Capability Executor\nadapter-specific sandbox"]
    Result["Result Envelope\ntext + metadata + audit"]

    Request --> Draft
    Draft --> Package
    Package --> Review
    Review --> Install
    Install --> Registry
    Registry --> ToolSchema
    ToolSchema --> Runtime
    Runtime --> Result

    subgraph Adapters["Supported Adapter Families"]
        Skill["skill\nread-only workflow instructions"]
        Web["webservice\nGET/POST to declared API"]
        MCP["mcp\nlocal HTTP JSON-RPC bridge"]
        Command["command\nfixed executable and args"]
        Native["native\napproved macOS actions"]
    end

    Runtime --> Skill
    Runtime --> Web
    Runtime --> MCP
    Runtime --> Command
    Runtime --> Native
```

## Design Decisions

- **Her Desktop 是产品主体**：它负责用户体验、状态机、上下文装配、权限、审计和本机工作区。不要把 UI 做成 AgentLLMAPI 或 AgentMem 的“薄壳客户端”。
- **AgentLLMAPI 是模型基础设施**：它负责 OpenAI-compatible 协议、路由、fallback、探针、计费与配额。Her Desktop 只依赖稳定 API，不感知具体上游模型。
- **AgentMem 是关系与事实中枢**：对话前同步 query，对话后异步 add；陪伴感来自长期 profile、relationship、偏好、意图和 dream consolidation，而不是只靠最近聊天记录。
- **Infiniti-Agent 是经验资产层**：继承 SOUL/INFINITI、project agent layout、skills 和 LiveUI/voice 设计，但不要把旧 CLI/TUI runtime 直接嵌入 Mac App 主链路。
- **插件不是“模型直接执行代码”**：所有能力必须先进入 manifest、review、registry、tool schema、executor、audit 这条链路，再被模型调用。
- **外部入口统一成 event**：Oyii、Discord、微信、浏览器、设备等未来入口都先归一化为 interaction event，进入同一个 Turn Runtime，避免每个入口各自长出一套 agent。
