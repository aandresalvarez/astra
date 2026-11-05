enum FixtureGoals {
    static func make(index: Int, sidebarOnly: Bool) -> String {
        if sidebarOnly {
            let prefix = "Synthetic sidebar task \(index). "
            return prefix + String(repeating: "g", count: 5040 - prefix.utf8.count)
        }
        // Preserve the measured workload: 336 repetitions, each 16 UTF-8 bytes.
        return String(repeating: "Synthetic goal. ", count: 336)
    }

    static func uniformByteCount<S: Sequence>(_ goals: S) -> Int? where S.Element == String {
        let sizes = Set(goals.map { $0.utf8.count })
        return sizes.count == 1 ? sizes.first : nil
    }
}
