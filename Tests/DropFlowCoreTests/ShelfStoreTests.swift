import AppKit
import Foundation
import Testing
@testable import DropFlowCore

extension SupportDirectoryTests {
    /// Shelf behaviour that has no view in it: de-duplication across drops, drop grouping, and the
    /// `itemsForDrag` contract that decides what leaves the shelf when the user starts a drag.
    ///
    /// Serialized: `DROPFLOW_SUPPORT_DIR` is process-wide state.
    ///
    /// **Not covered here:** `copyValue` / `copyValues`. Both write to `NSPasteboard.general`, so
    /// exercising them would overwrite whatever the person running the tests has on their clipboard.
    /// Testing them needs a pasteboard injection seam that does not exist yet — see the report.
    @Suite(.serialized)
    @MainActor
    struct ShelfStoreTests {
        private func drop(_ urls: [URL], into store: ShelfStore) {
            let pasteboard = makeScratchPasteboard()
            pasteboard.clearContents()
            pasteboard.writeObjects(urls.map { $0 as NSURL })
            defer { pasteboard.releaseGlobally() }
            store.addItems(from: pasteboard)
        }

        private func dropText(_ text: String, into store: ShelfStore) {
            let pasteboard = makeScratchPasteboard()
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            defer { pasteboard.releaseGlobally() }
            store.addItems(from: pasteboard)
        }

        // MARK: - De-duplication across separate drops

        /// `PasteboardReader` de-dupes only within a single drop, so dropping the same file again the
        /// next day used to add a second identical row that behaved identically to the first.
        @Test("Dropping the same file on two separate occasions yields one row")
        func dedupesAcrossDrops() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let file = try sandbox.makeFile(named: "same.txt")

                drop([file], into: store)
                #expect(store.items.count == 1)

                drop([file], into: store)
                #expect(store.items.count == 1, "the second drop of an already-shelved file must be ignored")
            }
        }

        @Test("A later drop adds only the files that are new")
        func partiallyOverlappingDrop() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let a = try sandbox.makeFile(named: "a.txt")
                let b = try sandbox.makeFile(named: "b.txt")

                drop([a], into: store)
                drop([a, b], into: store)

                #expect(store.items.map(\.displayName) == ["a.txt", "b.txt"])
            }
        }

        @Test("Identical text dropped twice yields one row")
        func dedupesText() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                dropText("remember the milk", into: store)
                dropText("remember the milk", into: store)
                #expect(store.items.count == 1)

                dropText("something else", into: store)
                #expect(store.items.count == 2)
            }
        }

        @Test("Removing a file and dropping it again re-adds it")
        func removeThenReAdd() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let file = try sandbox.makeFile(named: "again.txt")

                drop([file], into: store)
                let item = try #require(store.items.first)
                store.remove(item)
                #expect(store.items.isEmpty)

                drop([file], into: store)
                #expect(store.items.count == 1, "de-duplication must not outlive the row it de-duplicated against")
            }
        }

        // MARK: - Drop grouping

        @Test("A multi-file drop is grouped; a single-file drop is not")
        func groupingByDrop() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let single = try sandbox.makeFile(named: "single.txt")
                let pair = try [sandbox.makeFile(named: "p1.txt"), sandbox.makeFile(named: "p2.txt")]

                drop([single], into: store)
                #expect(store.items[0].dropGroupID == nil)

                drop(pair, into: store)
                let grouped = store.items.filter { $0.dropGroupID != nil }
                #expect(grouped.count == 2)
                #expect(Set(grouped.map(\.dropGroupID)).count == 1, "one drop is one group")

                // Three rows, but the pair collapses into one stack.
                let groups = store.displayGroups()
                #expect(groups.count == 2)
                #expect(groups.map(\.isStack) == [false, true])
            }
        }

        /// Current behaviour, worth pinning: when a two-file drop has one file filtered out as a
        /// duplicate, the single survivor is *not* given a group ID, because the grouping check runs
        /// after de-duplication.
        @Test("A drop reduced to one new file by de-duplication is not grouped")
        func groupingRunsAfterDeduplication() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let a = try sandbox.makeFile(named: "a.txt")
                let b = try sandbox.makeFile(named: "b.txt")

                drop([a], into: store)
                drop([a, b], into: store)

                let newRow = try #require(store.items.last)
                #expect(newRow.displayName == "b.txt")
                #expect(newRow.dropGroupID == nil)
            }
        }

        @Test("Ungrouping a stack turns it back into ordinary rows")
        func ungroupRestoresRows() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let pair = try [sandbox.makeFile(named: "p1.txt"), sandbox.makeFile(named: "p2.txt")]
                drop(pair, into: store)

                let stack = try #require(store.displayGroups().first { $0.isStack })
                store.ungroup(stack)

                #expect(store.items.allSatisfy { $0.dropGroupID == nil })
                #expect(store.displayGroups().count == 2)
                #expect(store.displayGroups().allSatisfy { !$0.isStack })
            }
        }

        // MARK: - itemsForDrag

        @Test("Simplify mode drags the whole shelf, whichever row the drag started from")
        func simplifyDragsEverything() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...3).map { try sandbox.makeFile(named: "f\($0).txt") }
                drop(files, into: store)
                #expect(store.dragMode == .simplify)

                for item in store.items {
                    #expect(store.itemsForDrag(startingWith: item).count == 3)
                }
            }
        }

        @Test("A file deleted from disk is excluded from the drag payload in both modes")
        func missingItemsAreNeverDragged() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...3).map { try sandbox.makeFile(named: "f\($0).txt") }
                drop(files, into: store)

                try FileManager.default.removeItem(at: files[1])
                store.refreshResolvedStates()

                #expect(store.items.count == 3, "the row stays on the shelf so the user can see it went missing")
                #expect(store.items[1].lastResolvedState == .missing)

                let payload = store.itemsForDrag(startingWith: store.items[0])
                #expect(payload.count == 2)
                #expect(payload.allSatisfy { $0.lastResolvedState != .missing })

                // Starting the drag *from* the missing row yields nothing rather than a broken promise.
                store.setDragMode(.advance)
                #expect(store.itemsForDrag(startingWith: store.items[1]).isEmpty)
            }
        }

        @Test("Advance mode drags the selection when the drag starts inside it")
        func advanceDragsSelection() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...3).map { try sandbox.makeFile(named: "f\($0).txt") }
                drop(files, into: store)
                store.setDragMode(.advance)

                let selected = [store.items[0], store.items[2]]
                store.selectOnly(selected)

                let payload = store.itemsForDrag(startingWith: store.items[0])
                #expect(payload.map(\.displayName) == ["f1.txt", "f3.txt"])
            }
        }

        @Test("Advance mode drags only the starting row when it is outside the selection")
        func advanceIgnoresSelectionWhenStartingOutsideIt() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...3).map { try sandbox.makeFile(named: "f\($0).txt") }
                drop(files, into: store)
                store.setDragMode(.advance)
                store.selectOnly([store.items[0]])

                let payload = store.itemsForDrag(startingWith: store.items[2])
                #expect(payload.map(\.displayName) == ["f3.txt"], "dragging an unselected row must not drag the selection instead")
            }
        }

        @Test("Advance mode with nothing selected drags just the starting row")
        func advanceWithEmptySelection() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...3).map { try sandbox.makeFile(named: "f\($0).txt") }
                drop(files, into: store)
                store.setDragMode(.advance)

                #expect(store.selectedIDs.isEmpty)
                #expect(store.itemsForDrag(startingWith: store.items[1]).map(\.displayName) == ["f2.txt"])
            }
        }

        /// The mode split for stacks: Simplify treats a stack drag as a whole-shelf drag, Advance
        /// confines it to the stack. `ux-03` called the Simplify default surprising; it is deliberate,
        /// and this pins it so a change has to be a decision rather than an accident.
        @Test("Dragging a stack: simplify takes the shelf, advance takes the stack")
        func stackDragContract() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let loose = try sandbox.makeFile(named: "loose.txt")
                let pair = try [sandbox.makeFile(named: "p1.txt"), sandbox.makeFile(named: "p2.txt")]
                drop([loose], into: store)
                drop(pair, into: store)

                let stack = try #require(store.displayGroups().first { $0.isStack })

                #expect(store.itemsForDrag(startingWith: stack).count == 3)
                store.setDragMode(.advance)
                #expect(store.itemsForDrag(startingWith: stack).map(\.displayName) == ["p1.txt", "p2.txt"])
            }
        }

        // MARK: - Selection and snapshots

        @Test("Clearing the shelf captures a snapshot that restores the same items")
        func clearThenRestore() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...2).map { try sandbox.makeFile(named: "s\($0).txt") }
                drop(files, into: store)

                store.clearShelf()
                #expect(store.items.isEmpty)
                #expect(store.recentSnapshots.count == 1)

                let snapshot = try #require(store.recentSnapshots.first)
                #expect(snapshot.title == "2 items")
                store.restore(snapshot: snapshot)
                #expect(store.items.map(\.displayName) == ["s1.txt", "s2.txt"])
            }
        }

        @Test("Clearing an empty shelf captures nothing")
        func clearEmptyShelfCapturesNothing() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                store.clearShelf()
                #expect(store.recentSnapshots.isEmpty, "an empty shelf would fill the Restore menu with blank entries")
            }
        }

        @Test("Removing a row drops it from the selection too")
        func removeClearsSelection() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...2).map { try sandbox.makeFile(named: "r\($0).txt") }
                drop(files, into: store)
                store.selectOnly(store.items)
                #expect(store.selectedIDs.count == 2)

                let doomed = store.items[0]
                store.remove(doomed)
                #expect(store.selectedIDs == [store.items[0].id])
                #expect(!store.selectedIDs.contains(doomed.id), "a stale selected ID would keep a deleted row in every drag payload")
            }
        }

        @Test("Toggling selection is additive and reversible")
        func toggleSelection() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let files = try (1...2).map { try sandbox.makeFile(named: "t\($0).txt") }
                drop(files, into: store)

                store.toggleSelection(for: store.items[0])
                store.toggleSelection(for: store.items[1])
                #expect(store.selectedIDs.count == 2)

                store.toggleSelection(for: store.items[0])
                #expect(store.selectedIDs == [store.items[1].id])
            }
        }

        // MARK: - Durability

        /// `save()` returns before the write happens, so at quit the process could exit first — the two
        /// 0-byte atomic-write sidecars in the real support directory are writes that started that way
        /// and never finished. `saveNow()` must have the bytes on disk by the time it returns, with no
        /// run-loop turn in between.
        @Test("saveNow leaves shelf.json on disk before it returns")
        func saveNowIsSynchronous() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let file = try sandbox.makeFile(named: "durable.txt")
                drop([file], into: store)

                try? FileManager.default.removeItem(at: sandbox.shelfJSON)
                #expect(!FileManager.default.fileExists(atPath: sandbox.shelfJSON.path))

                store.saveNow()

                #expect(FileManager.default.fileExists(atPath: sandbox.shelfJSON.path))
                let size = try Data(contentsOf: sandbox.shelfJSON).count
                #expect(size > 0, "a 0-byte shelf.json is the signature of an unfinished atomic write")

                let leftovers = try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path)
                    .filter { $0.contains("shelf.json.sb-") }
                #expect(leftovers.isEmpty)
            }
        }

        @Test("Snapshots are capped at ten")
        func snapshotsAreTrimmed() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                for index in 1...14 {
                    let file = try sandbox.makeFile(named: "snap\(index).txt")
                    drop([file], into: store)
                    store.clearShelf()
                }
                #expect(store.recentSnapshots.count == 10)
            }
        }
    }
}
