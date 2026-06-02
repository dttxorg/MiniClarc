import Foundation
import Testing
@testable import ClarcCore

// DEBUG-only smoke test: drives the TaskUpdateMessageFactory through a
// Bash lifecycle (start → enrich with input → finalize with result)
// and asserts the same id is reused and the status transitions
// running → done. This catches the most likely failure mode: a code
// refactor that ends up creating two cards for one tool call, or
// dropping the running state.
//
// Marked @Suite with a debug tag so the production test runner can
// skip it; enable in test plans targeted at this subsystem.

@Suite("TaskUpdateMessageFactory smoke")
struct TaskUpdateMessageFactorySmokeTests {

    @Test("Bash lifecycle: start → enrich → finalize keeps one id and runs done")
    func bashLifecycle() {
        // Simulate the three stream hooks:
        //   1. tool_use arrives            → makeRunning
        //   2. input_json_delta completes  → makeWithInput (same id, in-place update)
        //   3. tool_result arrives         → finalize (same id, in-place update)

        let toolId = "11111111-2222-3333-4444-555555555555"
        let input: [String: JSONValue] = [
            "command": .string("ls -la /tmp")
        ]
        let result = """
        total 8
        drwxrwxr-x  5 user  staff  160 Jun  2 12:00 .
        drwxr-xr-x  3 user  staff   96 Jun  2 11:00 ..
        """

        // 1. tool_use arrival
        let running = TaskUpdateMessageFactory.makeRunning(name: "Bash", id: toolId)
        #expect(running.status == .running)
        #expect(running.title == "Bash")
        #expect(running.endTime == nil)
        #expect(running.durationSeconds == nil)
        #expect(running.filesChanged.isEmpty)

        // 2. input_json_delta finalizes the parsed input.
        let enriched = TaskUpdateMessageFactory.makeWithInput(
            name: "Bash",
            id: toolId,
            input: input,
            existingStartTime: running.startTime
        )
        #expect(enriched.id == running.id)        // SAME id, in-place
        #expect(enriched.status == .running)     // still running
        #expect(enriched.startTime == running.startTime)
        #expect(enriched.summary == "ls -la /tmp")
        #expect(enriched.details.contains("ls -la /tmp"))
        #expect(enriched.endTime == nil)
        #expect(enriched.filesChanged.isEmpty)   // Bash has no files

        // 3. tool_result arrives
        let done = TaskUpdateMessageFactory.finalize(
            from: enriched,
            result: result,
            isError: false
        )
        #expect(done.id == running.id)
        #expect(done.status == .done)
        #expect(done.endTime != nil)
        #expect((done.durationSeconds ?? -1) >= 0)
        #expect(done.title == "Bash")
        #expect(done.summary.contains("total 8"))  // first line of result
    }

    @Test("Bash failure finalizes as .failed")
    func bashFailure() {
        let toolId = "22222222-3333-4444-5555-666666666666"
        let running = TaskUpdateMessageFactory.makeRunning(name: "Bash", id: toolId)
        let done = TaskUpdateMessageFactory.finalize(
            from: running,
            result: "Permission denied",
            isError: true
        )
        #expect(done.id == running.id)
        #expect(done.status == .failed)
        #expect(done.endTime != nil)
    }

    @Test("Edit extracts file path into summary and filesChanged")
    func editSummary() {
        let toolId = "33333333-4444-5555-6666-777777777777"
        let input: [String: JSONValue] = [
            "file_path": .string("Clarc/Services/ClaudeService.swift"),
            "old_string": .string("let x = 1"),
            "new_string": .string("let x = 2")
        ]
        let card = TaskUpdateMessageFactory.makeWithInput(
            name: "Edit",
            id: toolId,
            input: input,
            existingStartTime: nil
        )
        #expect(card.summary == "Clarc/Services/ClaudeService.swift")
        #expect(card.details.contains("let x = 1"))
        #expect(card.details.contains("let x = 2"))
        #expect(card.filesChanged.count == 1)
        #expect(card.filesChanged[0].path == "Clarc/Services/ClaudeService.swift")
        #expect(card.filesChanged[0].changeType == "modified")
    }

    @Test("Bash test output yields a testResults row")
    func bashTestResults() {
        let toolId = "44444444-5555-6666-7777-888888888888"
        let result = """
        Running tests...
        TestFoo .... passed
        TestBar .... passed
        TestBaz .... FAILED

        2 passed, 1 failed in 0.5s
        """
        let running = TaskUpdateMessageFactory.makeRunning(name: "Bash", id: toolId)
        let done = TaskUpdateMessageFactory.finalize(
            from: running,
            result: result,
            isError: false
        )
        #expect(done.testResults.count == 1)
        #expect(done.testResults[0].name == "Tests")
        #expect(done.testResults[0].status == "failed")  // 1 failed > 0
    }
}
