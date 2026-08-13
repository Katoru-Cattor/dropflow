import Foundation
import Testing
@testable import DropFlowCore

/// The updater installs whatever the latest GitHub release says, so this comparison decides whether
/// a self-installer runs at all. A string compare here would rank "0.9.0" above "0.10.0" and strand
/// every user on the older build; the reverse mistake offers a downgrade on every launch.
@Suite
struct VersionCompareTests {
    @Test("Version ordering is numeric, component-wise", arguments: [
        // candidate, current, expected
        ("0.10.0", "0.9.0", true),      // the case a lexicographic compare gets wrong
        ("0.9.0", "0.10.0", false),
        ("1.0.0", "0.9.9", true),
        ("2.0.0", "10.0.0", false),
        ("1.0.10", "1.0.9", true),
        ("1.0.1", "1.0.0", true),
        ("0.0.1", "0.0.0", true)
    ])
    func numericOrdering(_ candidate: String, _ current: String, _ expected: Bool) {
        #expect(VersionCompare.isNewer(candidate, than: current) == expected)
    }

    @Test("An identical version is not newer", arguments: ["1.0.0", "0.1.0", "12.34.56", "1"])
    func equalIsNotNewer(_ version: String) {
        #expect(VersionCompare.isNewer(version, than: version) == false, "equality must not trigger a re-install loop")
    }

    @Test("Missing trailing components count as zero", arguments: [
        ("1.0", "1.0.0", false),
        ("1.0.0", "1.0", false),
        ("1.1", "1.0.9", true),
        ("1", "1.0.0", false),
        ("2", "1.9.9", true)
    ])
    func missingComponentsAreZero(_ candidate: String, _ current: String, _ expected: Bool) {
        #expect(VersionCompare.isNewer(candidate, than: current) == expected)
    }

    /// An empty or unparseable tag must never look like an upgrade — that is the input a malformed
    /// or hand-typed GitHub release produces, and it would otherwise arm the installer.
    @Test("A malformed or empty tag never triggers an update", arguments: [
        "", " ", "latest", "abc", "..", "v", "nightly", "release-candidate", "0.0.0"
    ])
    func malformedTagsNeverUpdate(_ tag: String) {
        #expect(VersionCompare.isNewer(tag, than: "1.2.3") == false, "\(tag.debugDescription) was treated as newer than 1.2.3")
    }

    /// `isNewer` does no `v`-stripping of its own — `UpdateController.parseRelease` removes the
    /// prefix before calling it. This pins that dependency: if the strip is ever removed, a
    /// "v1.2.3" tag silently stops being offered as an update rather than failing loudly.
    @Test("A raw v-prefixed tag is NOT recognised, so parseRelease must keep stripping it")
    func vPrefixIsNotHandledHere() {
        #expect(VersionCompare.isNewer("v2.0.0", than: "1.0.0") == false)
        #expect(VersionCompare.isNewer("2.0.0", than: "1.0.0") == true)
    }

    /// The fallback when Info.plist carries no CFBundleShortVersionString is "0.0.0", so any real
    /// release must beat it — otherwise an unversioned build never updates.
    @Test("Any real version beats the 0.0.0 fallback", arguments: ["0.0.1", "0.1.0", "1.0.0"])
    func realVersionsBeatFallback(_ version: String) {
        #expect(VersionCompare.isNewer(version, than: "0.0.0") == true)
    }

    @Test("Trailing non-numeric junk in a component is ignored, not fatal")
    func numericPrefixOfComponent() {
        // "1.2.3-beta" -> [1, 2, 3]; the pre-release suffix is invisible to the comparison, so a
        // beta and its final release are indistinguishable. Current behaviour, pinned deliberately.
        #expect(VersionCompare.isNewer("1.2.3-beta", than: "1.2.3") == false)
        #expect(VersionCompare.isNewer("1.2.4-beta", than: "1.2.3") == true)
    }
}
