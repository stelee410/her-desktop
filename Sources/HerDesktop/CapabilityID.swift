import Foundation

/// Compiler-checked names for built-in capability IDs.
///
/// Capability IDs were raw string literals repeated 5–10× across dispatch,
/// approval, prompts, and manifests — renaming one was a whole-repo
/// find-and-replace with zero compiler help, and a typo silently routed to
/// the wrong handler. Reference these constants instead of typing literals;
/// the JSON manifests remain the source of truth for what each ID *means*.
enum CapabilityID {
    // Shell
    static let shellRun = "shell.run"
    static let shellInspect = "shell.inspect"

    // Browser
    static let browserOpen = "browser.open"
    static let browserRead = "browser.read"
    static let browserNavigate = "browser.navigate"
    static let browserClick = "browser.click"
    static let browserType = "browser.type"
    static let browserDetect = "browser.detect"

    // Terminal
    static let terminalOpen = "terminal.open"
    static let terminalRead = "terminal.read"
    static let terminalSend = "terminal.send"

    // WebApps
    static let webappCreate = "webapp.create"
    static let webappUpdate = "webapp.update"
    static let webappRemove = "webapp.remove"
    static let webappList = "webapp.list"
    static let webappOpen = "webapp.open"
    static let webappQuery = "webapp.query"
    static let webappExecute = "webapp.execute"
    static let webappInspect = "webapp.inspect"
    static let webappRequest = "webapp.request"

    // Plugins
    static let pluginDraft = "plugin.draft"
    static let pluginInspect = "plugin.inspect"
    static let pluginInstall = "plugin.install"
    static let pluginInstallDraft = "plugin.installDraft"
    static let pluginDiscardDraft = "plugin.discardDraft"
    static let pluginListDrafts = "plugin.listDrafts"
    static let pluginListInstalled = "plugin.listInstalled"
    static let pluginReadFile = "plugin.readFile"
    static let pluginRemove = "plugin.remove"
    static let pluginExport = "plugin.export"
    static let pluginStagePackage = "plugin.stagePackage"

    // Workspace
    static let workspaceInspect = "workspace.inspect"
    static let workspaceSearch = "workspace.search"
    static let workspaceWriteTextFile = "workspace.writeTextFile"
    static let workspaceReplaceText = "workspace.replaceText"

    // Heartbeat / scheduled tasks
    static let scheduleCreate = "schedule.create"
    static let scheduleList = "schedule.list"
    static let scheduleCancel = "schedule.cancel"

    // Native / memory / misc
    static let nativeNotify = "native.notify"
    static let nativeSpeak = "native.speak"
    static let nativeReadTextFile = "native.readTextFile"
    static let nativeInspectAttachment = "native.inspectAttachment"
    static let agentmemQuery = "agentmem.query"
    static let agentmemAdd = "agentmem.add"
    static let mcpDiscover = "mcp.discover"
    static let inboxCapture = "inbox.capture"
    static let productDiagnostics = "product.diagnostics"
    static let productExportDiagnostics = "product.exportDiagnostics"
    static let reflectionSnapshot = "reflection.snapshot"
    static let workspacePlan = "workspace.plan"
}
