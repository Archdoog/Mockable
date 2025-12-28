//
//  LockedValue.swift
//  Mockable
//
//  Created by Kolos Foltanyi on 2024. 12. 16..
//
import Foundation

/// A generic wrapper for isolating a mutable value with a lock.
///
/// If you trust the sendability of the underlying value, consider using ``UncheckedSendable``,
/// instead.
@dynamicMemberLookup
final class LockedValue<Value>: @unchecked Sendable {
    private var _value: Value
    private let lock = NSRecursiveLock()
    private var didSet: ((Value) -> Void)?

    /// When a `withValue(_:)` call is active we keep a working copy here. Nested
    /// `withValue(_:)` calls operate on the same working copy so inner changes
    /// are not lost when the outer call commits.
    private var activeTransactionValue: Value?
    private var activeTransactionDepth: Int = 0

    /// Initializes lock-isolated state around a value.
    ///
    /// - Parameter value: A value to isolate with a lock.
    init(_ value: @autoclosure @Sendable () throws -> Value) rethrows {
        self._value = try value()
    }

    subscript<Subject>(dynamicMember keyPath: KeyPath<Value, Subject>) -> Subject {
        self.lock.criticalRegion {
            (self.activeTransactionValue ?? self._value)[keyPath: keyPath]
        }
    }

    /// Perform an operation with isolated access to the underlying value.
    ///
    /// Useful for modifying a value in a single transaction.
    ///
    /// ```swift
    /// // Isolate an integer for concurrent read/write access:
    /// var count = LockedValue(0)
    ///
    /// func increment() {
    ///   // Safely increment it:
    ///   self.count.withValue { $0 += 1 }
    /// }
    /// ```
    ///
    /// - Parameter operation: An operation to be performed on the the underlying value with a lock.
    /// - Returns: The result of the operation.
    func withValue<T>(
        _ operation: (inout Value) throws -> T
    ) rethrows -> T {
        try self.lock.criticalRegion {
            // If this is the outermost call we create a working copy and commit
            // it when the outermost call completes. Nested calls share the same
            // working copy so inner modifications are preserved.
            let isRoot = self.activeTransactionDepth == 0
            if isRoot {
                self.activeTransactionValue = self._value
            }
            self.activeTransactionDepth += 1
            defer {
                self.activeTransactionDepth -= 1
                if isRoot {
                    // Commit working copy to storage and notify.
                    self._value = self.activeTransactionValue!
                    let newValue = self._value
                    self.activeTransactionValue = nil
                    self.didSet?(newValue)
                }
            }

            // Safe to force-unwrap: either we've just created the working copy
            // for the root call, or a root call has already created it.
            return try operation(&self.activeTransactionValue!)
        }
    }

    /// Overwrite the isolated value with a new value.
    ///
    /// ```swift
    /// // Isolate an integer for concurrent read/write access:
    /// var count = LockedValue(0)
    ///
    /// func reset() {
    ///   // Reset it:
    ///   self.count.setValue(0)
    /// }
    /// ```
    ///
    /// > Tip: Use ``withValue(_:)`` instead of ``setValue(_:)`` if the value being set is derived
    /// > from the current value. That is, do this:
    /// >
    /// > ```swift
    /// > self.count.withValue { $0 += 1 }
    /// > ```
    /// >
    /// > ...and not this:
    /// >
    /// > ```swift
    /// > self.count.setValue(self.count + 1)
    /// > ```
    /// >
    /// > ``withValue(_:)`` isolates the entire transaction and avoids data races between reading and
    /// > writing the value.
    ///
    /// - Parameter newValue: The value to replace the current isolated value with.
    func setValue(_ newValue: @autoclosure () throws -> Value) rethrows {
        try self.lock.criticalRegion {
            let value = try newValue()
            // If a transaction is active, modify the working copy so the change
            // becomes part of the transaction and will be committed by the outermost call.
            if self.activeTransactionDepth > 0 {
                self.activeTransactionValue = value
            } else {
                self._value = value
                self.didSet?(self._value)
            }
        }
    }
}

extension LockedValue where Value: Sendable {
    var value: Value {
        self.lock.criticalRegion {
            self.activeTransactionValue ?? self._value
        }
    }

    /// Initializes lock-isolated state around a value.
    ///
    /// - Parameter value: A value to isolate with a lock.
    /// - Parameter didSet: A callback to invoke when the value changes.
    convenience init(
        _ value: @autoclosure @Sendable () throws -> Value,
        didSet: (@Sendable (Value) -> Void)? = nil
    ) rethrows {
        try self.init(value())
        self.didSet = didSet
    }
}

extension NSRecursiveLock {
    @inlinable @discardableResult
    func criticalRegion<R>(work: () throws -> R) rethrows -> R {
        self.lock()
        defer { self.unlock() }
        return try work()
    }
}
