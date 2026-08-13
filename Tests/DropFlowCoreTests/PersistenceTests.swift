import AppKit
import Foundation
import Testing
@testable import DropFlowCore

extension SupportDirectoryTests {
    /// `shelf.json` is the only copy of the shelf plus all ten snapshots, and the app now ships an
    /// updater — so a schema change can reach every user at once. These tests exist so that the day
    /// someone adds a field to `ShelfItem`, a test fails instead of a user's shelf disappearing.
    ///
    /// Serialized: `DROPFLOW_SUPPORT_DIR` is process-wide state.
    @Suite(.serialized)
    @MainActor
    struct PersistenceTests {
        /// The very coders `ShelfStore` uses, not a copy of their configuration. A hand-copy would
        /// keep passing while production's format drifted, which defeats the purpose of these tests.
        private func makeCoders() -> (JSONEncoder, JSONDecoder) {
            (ShelfStore.ShelfCoders.makeEncoder(), ShelfStore.ShelfCoders.makeDecoder())
        }

        // MARK: - Round trip

        @Test("A saved shelf reloads with the same items in the same order")
        func roundTripThroughStore() async throws {
            try await SupportSandbox.run { sandbox in
                let store = sandbox.makeStore()
                let first = try sandbox.makeFile(named: "alpha.txt")
                let second = try sandbox.makeFile(named: "beta.txt")

                for url in [first, second] {
                    let pasteboard = makeScratchPasteboard()
                    pasteboard.clearContents()
                    pasteboard.writeObjects([url as NSURL])
                    store.addItems(from: pasteboard)
                }
                #expect(store.items.count == 2)
                store.saveNow()

                let reloaded = sandbox.makeStore()
                reloaded.load()
                #expect(reloaded.items.map(\.displayName) == ["alpha.txt", "beta.txt"])
                #expect(reloaded.items.allSatisfy { $0.lastResolvedState == .resolved })
            }
        }

        // MARK: - Forward compatibility

        @Test("A shelf.json carrying only the required fields still decodes")
        func decodesMinimalItem() async throws {
            try await SupportSandbox.run { sandbox in
                // Every optional field omitted: no sourceURLString, bookmarkData, inlineText or
                // dropGroupID. This is the shape an older build would have written.
                try sandbox.write(shelfJSON: """
                {
                  "activeItems": [
                    {
                      "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                      "kind": "text",
                      "displayName": "hello",
                      "createdAt": "2026-01-01T00:00:00Z",
                      "lastResolvedState": "inline"
                    }
                  ],
                  "recentSnapshots": []
                }
                """)

                let store = sandbox.makeStore()
                store.load()

                #expect(store.items.count == 1)
                #expect(store.items.first?.displayName == "hello")
                try #expect(sandbox.corruptSidecars().isEmpty)
                #expect(FileManager.default.fileExists(atPath: sandbox.shelfJSON.path))
            }
        }

        @Test("An unknown extra field is ignored rather than fatal")
        func ignoresUnknownField() async throws {
            try await SupportSandbox.run { sandbox in
                try sandbox.write(shelfJSON: """
                {
                  "activeItems": [
                    {
                      "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                      "kind": "text",
                      "displayName": "hello",
                      "createdAt": "2026-01-01T00:00:00Z",
                      "lastResolvedState": "inline",
                      "aFieldFromSomeFutureVersion": 42
                    }
                  ],
                  "recentSnapshots": []
                }
                """)

                let store = sandbox.makeStore()
                store.load()
                #expect(store.items.count == 1)
                try #expect(sandbox.corruptSidecars().isEmpty)
            }
        }

        /// This is the landmine the whole file is here to guard. Synthesized `Codable` ignores property
        /// default values, so adding **any** non-optional field to `ShelfItem` makes `init(from:)` throw
        /// `keyNotFound` against every file already on a user's disk. A new field must be an Optional
        /// (or carry a hand-written `init(from:)`); this test proves why.
        @Test("A required field missing from an older file throws keyNotFound, not a silent default")
        func missingRequiredFieldThrows() throws {
            let (_, decoder) = makeCoders()
            // "createdAt" omitted — stands in for any newly added non-optional field.
            let json = Data("""
            {
              "activeItems": [
                {
                  "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427",
                  "kind": "text",
                  "displayName": "hello",
                  "lastResolvedState": "inline"
                }
              ],
              "recentSnapshots": []
            }
            """.utf8)

            var thrownKey: String?
            do {
                _ = try decoder.decode(ShelfPersistence.self, from: json)
            } catch let DecodingError.keyNotFound(key, _) {
                thrownKey = key.stringValue
            }
            #expect(thrownKey == "createdAt", "adding a non-optional field breaks every existing shelf.json")
        }

        // MARK: - Quarantine

        @Test("An undecodable shelf.json is preserved as shelf.json.corrupt-<ts>, byte for byte")
        func corruptFileIsQuarantined() async throws {
            try await SupportSandbox.run { sandbox in
                let original = "{ this is not json at all"
                try sandbox.write(shelfJSON: original)
                let originalBytes = try Data(contentsOf: sandbox.shelfJSON)

                let store = sandbox.makeStore()
                store.load()

                #expect(store.items.isEmpty)
                #expect(!FileManager.default.fileExists(atPath: sandbox.shelfJSON.path), "shelf.json was moved aside, not left in place")

                let sidecars = try sandbox.corruptSidecars()
                #expect(sidecars.count == 1)
                let preserved = try #require(sidecars.first)
                let preservedBytes = try Data(contentsOf: sandbox.directory.appendingPathComponent(preserved))
                #expect(preservedBytes == originalBytes, "the user's bytes must survive intact for recovery")
            }
        }

        /// The failure mode that matters is not the failed read — it is the *next save* flattening the
        /// only copy of the data. `load()`'s catch branch deliberately does not call `postChange()`, so
        /// nothing is scheduled. Waiting past the 0.2 s save debounce proves it.
        @Test("A failed load never schedules a save that would overwrite the shelf")
        func failedLoadDoesNotWriteBack() async throws {
            try await SupportSandbox.run { sandbox in
                try sandbox.write(shelfJSON: "{ truncated")

                let store = sandbox.makeStore()
                store.load()
                #expect(!FileManager.default.fileExists(atPath: sandbox.shelfJSON.path))

                // Longer than ShelfStore's 0.2 s scheduleSave debounce.
                try await Task.sleep(for: .milliseconds(500))

                #expect(!FileManager.default.fileExists(atPath: sandbox.shelfJSON.path), "an empty shelf was written over the quarantined data")
                try #expect(sandbox.corruptSidecars().count == 1)
            }
        }

        /// A file that parses as JSON but not as the current schema takes the same path as garbage —
        /// this is the exact case a future schema change produces.
        @Test("A schema mismatch is quarantined, not reset")
        func schemaMismatchIsQuarantined() async throws {
            try await SupportSandbox.run { sandbox in
                try sandbox.write(shelfJSON: """
                {
                  "activeItems": [
                    { "id": "1B4E28BA-2FA1-11D2-883F-0016D3CCA427", "kind": "text", "displayName": "hello", "lastResolvedState": "inline" }
                  ],
                  "recentSnapshots": []
                }
                """)

                let store = sandbox.makeStore()
                store.load()

                #expect(store.items.isEmpty)
                try #expect(sandbox.corruptSidecars().count == 1)
                #expect(!FileManager.default.fileExists(atPath: sandbox.shelfJSON.path))
            }
        }

        @Test("A first launch with no shelf.json leaves no corrupt sidecar behind")
        func missingFileIsNotQuarantined() async throws {
            try await SupportSandbox.run { sandbox in
                #expect(!FileManager.default.fileExists(atPath: sandbox.shelfJSON.path))

                let store = sandbox.makeStore()
                store.load()

                #expect(store.items.isEmpty)
                try #expect(sandbox.corruptSidecars().isEmpty, "a first launch must not look like corruption")
            }
        }

        /// Documents a real limitation rather than asserting it is fine: the quarantine name has
        /// one-second resolution and the move is `try?`, so two failed loads inside the same second
        /// leave the second corrupt file sitting at `shelf.json`, where the next successful save can
        /// overwrite it. Harmless in the shipping app (load runs once per launch) but a trap for
        /// anyone who calls `load()` twice. Asserting CURRENT behaviour — see the report.
        @Test("Two failed loads in the same second: the second file is not quarantined again")
        func quarantineNameCollidesWithinOneSecond() async throws {
            try await SupportSandbox.run { sandbox in
                try sandbox.write(shelfJSON: "{ first")
                let store = sandbox.makeStore()
                store.load()
                try #expect(sandbox.corruptSidecars().count == 1)

                try sandbox.write(shelfJSON: "{ second")
                store.load()

                // Observed behaviour: the sidecar name has one-second resolution, so the second move's
                // destination already exists, `moveItem` throws, and the `try?` swallows it — leaving
                // the second corrupt file at shelf.json. Nothing is lost, because a failed load
                // schedules no save, but the quarantine is not idempotent.
                try #expect(sandbox.corruptSidecars().count == 1, "the same-second name collided, so no second sidecar appeared")
                #expect(
                    FileManager.default.fileExists(atPath: sandbox.shelfJSON.path),
                    "a file that could not be moved aside must stay on disk, never be silently deleted"
                )
                try #expect(Data(contentsOf: sandbox.shelfJSON) == Data("{ second".utf8))
            }
        }
    }
}
