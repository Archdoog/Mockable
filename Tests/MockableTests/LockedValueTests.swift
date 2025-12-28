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

    /// When `withValue(_:)` is nested, inner modifications must not be lost when
    /// the outer transaction completes. This used to be broken when the outer
    /// call kept its own copy and always wrote it back on exit (overwriting the
    /// inner changes).
    func test_nested_withValue_preserves_inner_modifications() {
        let lv = LockedValue([Int]())

        lv.withValue { arr in
            arr.append(1)

            // nested transaction mutates the same logical value
            lv.withValue { inner in
                inner.append(2)
            }

            arr.append(3)
        }

        XCTAssertEqual(lv.value, [1, 2, 3], "Nested transaction modifications should be preserved")
    }

    /// Ensure that calling `setValue(_:)` while a transaction is active updates
    /// the working copy (so the change is visible inside the transaction and
    /// committed at the end).
    func test_setValue_during_transaction_updates_working_copy() {
        let lv = LockedValue(0)

        lv.withValue { value in
            value = 1
            // mutate via setValue while a transaction is active
            lv.setValue(2)

            // Reading `.value` from inside the transaction should reflect the working copy
            XCTAssertEqual(lv.value, 2, "setValue inside a transaction must update the transaction working copy")
        }

        // After transaction commits the stored value should be the last set value
        XCTAssertEqual(lv.value, 2)
    }

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