import Foundation
import Testing
@testable import ClarcCore

@MainActor
@Suite("TaskProgressStore")
struct TaskProgressStoreTests {

    @Test("start creates a running task and returns its id")
    func start() {
        let store = TaskProgressStore()
        let id = store.start(title: "Implementation", summary: "in progress")
        let task = store.tasks[id]
        #expect(task != nil)
        #expect(task?.title == "Implementation")
        #expect(task?.summary == "in progress")
        #expect(task?.status == .running)
    }

    @Test("update fills only the non-nil fields")
    func updatePartial() async {
        let store = TaskProgressStore()
        let id = store.start(title: "T", summary: "s")
        try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
        store.update(id: id, summary: "new", details: nil, filesChanged: nil, testResults: nil)
        let task = store.tasks[id]
        #expect(task?.summary == "new")
        #expect(task?.details == "")
    }

    @Test("finish sets endTime and durationSeconds")
    func finishSetsDuration() async {
        let store = TaskProgressStore()
        let id = store.start(title: "T", summary: "s")
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        store.finish(id: id, summary: "done", details: nil, status: .done)
        let task = store.tasks[id]
        #expect(task?.status == .done)
        #expect(task?.endTime != nil)
        #expect((task?.durationSeconds ?? 0) > 0)
    }

    @Test("fail is finish with .failed")
    func failSetsFailed() {
        let store = TaskProgressStore()
        let id = store.start(title: "T", summary: "s")
        store.fail(id: id, summary: "oops", details: nil)
        #expect(store.tasks[id]?.status == .failed)
        #expect(store.tasks[id]?.summary == "oops")
    }

    @Test("upsert with a new id is wasNew=true and the message goes in unchanged")
    func upsertNew() {
        let store = TaskProgressStore()
        let update = TaskUpdateMessage(title: "T", summary: "s", status: .running)
        let (wasNew, merged) = store.upsert(update)
        #expect(wasNew == true)
        #expect(merged == update)
        #expect(store.tasks[update.id] == update)
    }

    @Test("upsert with an existing id preserves startTime and writes duration when done")
    func upsertPreservesStartTime() async {
        let store = TaskProgressStore()
        let id = store.start(title: "T", summary: "s")
        try? await Task.sleep(nanoseconds: 50_000_000)
        let endTime = Date()
        let update = TaskUpdateMessage(
            id: id, title: "T", summary: "done",
            status: .done, startTime: Date(timeIntervalSince1970: 0),
            endTime: endTime
        )
        let (wasNew, merged) = store.upsert(update)
        #expect(wasNew == false)
        // Original startTime is preserved
        #expect(merged.startTime == store.tasks[id]?.startTime)
        // duration is recomputed because status is done
        #expect(merged.durationSeconds != nil)
    }

    @Test("isExpanded defaults: running=true, done=false, failed=true")
    func isExpandedDefaults() {
        let store = TaskProgressStore()
        let runningID = store.start(title: "R", summary: "")
        let doneID = store.start(title: "D", summary: "")
        store.finish(id: doneID, summary: nil, details: nil, status: .done)
        let failedID = store.start(title: "F", summary: "")
        store.fail(id: failedID, summary: nil, details: nil)

        #expect(store.isExpanded(store.tasks[runningID]!) == true)
        #expect(store.isExpanded(store.tasks[doneID]!) == false)
        #expect(store.isExpanded(store.tasks[failedID]!) == true)
    }

    @Test("isExpanded respects manual override")
    func isExpandedOverride() {
        let store = TaskProgressStore()
        let id = store.start(title: "R", summary: "")
        // Default: running → true
        #expect(store.isExpanded(store.tasks[id]!) == true)
        // User collapses
        store.setExpanded(false, for: id)
        #expect(store.isExpanded(store.tasks[id]!) == false)
        // User re-expands
        store.setExpanded(true, for: id)
        #expect(store.isExpanded(store.tasks[id]!) == true)
    }
}
