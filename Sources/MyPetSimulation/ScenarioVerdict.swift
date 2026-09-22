import MyPetCore
import MyPetEngine

extension SemanticPipeline {
    func logicVerdict(kernel: GameKernel, expectations: ScenarioExpectations) -> LogicVerdict {
        var failures = logicFailures
        failures.append(contentsOf: expectations.check(kernel: kernel, pipelineTrace: trace))
        return LogicVerdict(failures: Array(Set(failures)).sorted())
    }
}
