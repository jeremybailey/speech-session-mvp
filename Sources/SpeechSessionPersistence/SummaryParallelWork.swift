import Foundation

public enum SummaryParallelWork {
    /// Bounded in-flight operations; output order stays identical to input order.
    public static func map<Input: Sendable, Output: Sendable>(_ inputs: [Input], limit: Int,
        operation: @escaping @Sendable (Input) async throws -> Output) async throws -> [Output] {
        try await withThrowingTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            var results: [Int: Output] = [:]
            func submit(_ index: Int) {
                group.addTask { try Task.checkCancellation(); return (index, try await operation(inputs[index])) }
            }
            while next < min(max(1, limit), inputs.count) { submit(next); next += 1 }
            while let (index, value) = try await group.next() {
                try Task.checkCancellation()
                results[index] = value
                if next < inputs.count { submit(next); next += 1 }
            }
            return inputs.indices.map { results[$0]! }
        }
    }
}
