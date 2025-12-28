//
// LockedValueTests.swift
// Mockable
//
// Tests for the LockedValue transactional behavior and a guard test for
// Matcher.reset() to cover the re-entrancy scenario uncovered during review.
//
// Created by automated patch
//

import XCTest
@testable import Mockable

final class LockedValueTests: XCTestCase {





    /// The `Matcher.reset()` implementation used to call registration helpers
    /// while inside a `withValue` transaction which lead to a re-entrancy
    /// overwrite (inner registration would be lost when the outer transaction
    /// committed). This regression test ensures default comparators are present
    /// after a reset.
    func test_matcher_reset_registers_default_types() {
        // Reset the current matcher (task-local or global) and verify that
        // default comparators exist afterwards.
        Matcher.reset()

        XCTAssertNotNil(Matcher.comparator(for: Int.self), "Int comparator must be registered by default")
        XCTAssertNotNil(Matcher.comparator(for: [Int].self), "Array comparator must be registered by default")
        XCTAssertNotNil(Matcher.comparator(for: String.self), "String comparator must be registered by default")
    }

    /// A basic concurrency stress test that performs many concurrent increments
    /// using `withValue(_:)`. This helps catch obvious synchronization issues.
    func test_concurrent_increments_are_safe() {
        let lv = LockedValue(0)
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .default)

        let tasks = 50
        let incrementsPerTask = 200

        for _ in 0..<tasks {
            group.enter()
            queue.async {
                for _ in 0..<incrementsPerTask {
                    lv.withValue { $0 += 1 }
                }
                group.leave()
            }
        }

        // Wait up to a few seconds for the concurrent work to finish
        let waitResult = group.wait(timeout: .now() + .seconds(5))
        XCTAssertEqual(waitResult, .success, "Timed out waiting for concurrent tasks to finish")

        XCTAssertEqual(lv.value, tasks * incrementsPerTask, "All increments must be accounted for")
    }
}