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

    func test_reentrant_nested_mutations_are_preserved() {
        let lv = LockedValue(0)
        lv.withValue { value in
            value += 1
            lv.withValue { value in
                value += 1
            }
        }
        XCTAssertEqual(lv.value, 2, "Nested mutations must be preserved")
    }

    func test_withValue_allows_nested_writes_on_collections() {
        let lv = LockedValue([Int]())
        lv.withValue { arr in
            arr.append(1)
            lv.withValue { arr in
                arr.append(2)
            }
        }
        XCTAssertEqual(lv.value, [1, 2], "Nested collection mutations must be preserved")
    }

    func test_setValue_inside_transaction_preserved_until_commit() {
        let lv = LockedValue(0)
        lv.withValue { value in
            // Update the working buffer via `setValue(_:)` while inside the
            // transaction and then mutate it again via the inout parameter.
            lv.setValue(5)
            value += 1
        }
        XCTAssertEqual(lv.value, 6, "setValue(_:) inside a transaction must update the working buffer")
    }
}