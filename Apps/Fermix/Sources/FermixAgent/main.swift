import FermixAppCore
import Foundation

exit(
    AgentEntryPoint.main(
        arguments: CommandLine.arguments,
        bundleRoot: Bundle.main.bundleURL,
        architecture: EngineResolver.hostArchitecture,
        output: StandardAgentOutput()
    )
)
