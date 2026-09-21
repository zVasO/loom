import LoomCLI
import Foundation

// loom — the CLI and MCP server of the agents API (ADR-0010). A thin shell:
// everything lives in LoomCLI, where the tests can reach it.
exit(CLI.run(Array(CommandLine.arguments.dropFirst())))
