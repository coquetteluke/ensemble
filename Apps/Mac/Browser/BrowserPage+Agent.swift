import AppKit
import WebKit
import EnsembleKit

/// The agent tools drive the pane's own web view: the same private data store, navigation rules and console, with
/// their scripts in Ensemble's content world (`world`), where the page cannot reach them. Pages the agent opens go
/// through `load`, like the address bar.
extension BrowserPage: AgentBrowserSurface {
    var agentWebView: WKWebView { webView }
    var agentWorld: WKContentWorld { world }
    var agentURL: URL? { url }
    var agentConsole: [BrowserConsoleLine] { console }
    var agentConsoleEntries: [AgentBrowserConsoleEntry] { agentTaggedConsoleEntries }

    func agentOpen(_ target: URL) {
        load(target)
    }

    func agentSetNavigationOriginLock(_ expectedOrigin: String?) {
        setAgentNavigationOriginLock(expectedOrigin)
    }

    var agentBlockedNavigationTarget: String? {
        agentBlockedRedirectTarget
    }
}
