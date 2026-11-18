import Foundation

// `ensemble-agent-tools`: the small helper each engine starts as Ensemble's stdio MCP server. It connects to the
// running app's private socket, proves which session it serves with that session's key, and relays bytes both ways.
// All the logic is in `AgentToolsBridge` (shared with EnsembleKit, compiled into this target as well).
exit(AgentToolsBridge.run())
