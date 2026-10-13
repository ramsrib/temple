import Darwin
import TempleCLIKit

// `temple`: the command line over Temple's open sessions and History (ADR-034).
exit(await TempleCLI.main(CommandLine.arguments).rawValue)
