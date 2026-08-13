import Foundation

/// Release-version ordering for the updater, lifted out of `UpdateController` so it can be tested.
/// It decides whether a self-installing update is offered at all, so a wrong answer here either
/// strands users on an old build or downgrades them.
public enum VersionCompare {
    /// Numeric, component-wise. "0.10.0" beats "0.9.0"; equal versions are not newer.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return false
    }
}
