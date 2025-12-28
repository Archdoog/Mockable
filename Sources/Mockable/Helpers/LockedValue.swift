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

    // An optional heap-backed working buffer used when a transaction is active.
    // We allocate this lazily for the duration of the outermost `withValue(_:)`
    // call and reuse it for nested calls. This permits re-entrant mutations on
    // the same working buffer while avoiding stack-based exclusivity traps.
    private var reentrancyBuffer: UnsafeMutablePointer<Value>?
    private var reentrancyDepth: Int = 0

    /// Perform mutating operations on the isolated value.
    ///
    /// This `withValue(_:)` implementation supports re-entrant calls on the same
    /// `LockedValue`. Re-entrancy is implemented by allocating a single
    /// heap-backed working buffer for the duration of the outermost transaction
    /// and reusing that buffer for nested calls. Inner changes will therefore
    /// be visible to outer calls and will not be lost when the outer call
    /// completes.
    ///
    /// - Important: This is a synchronous, lock-based implementation and only
    ///   isolates state across threads. It does not provide Swift actor
    ///   isolation and does not prevent scheduling or re-entrancy related
    ///   hazards at higher architectural boundaries.

    /// Initializes lock-isolated state around a value.
    ///
    /// - Parameter value: A value to isolate with a lock.
    init(_ value: @autoclosure @Sendable () throws -> Value) rethrows {
        self._value = try value()
    }

    subscript<Subject>(dynamicMember keyPath: KeyPath<Value, Subject>) -> Subject {
        self.lock.criticalRegion {
            if let buffer = self.reentrancyBuffer {
                buffer.pointee[keyPath: keyPath]
            } else {
                self._value[keyPath: keyPath]
            }
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
            // If a working buffer is already present, we are re-entering a
            // transaction. Reuse the existing buffer so nested mutations are
            // applied to the same working state.
            if let buffer = self.reentrancyBuffer {
                self.reentrancyDepth += 1
                defer { self.reentrancyDepth -= 1 }
                return try self.callInoutOperation(operation, withPointer: buffer)
            }

            // Top-level entry: create a heap-backed working buffer and
            // commit its final value back to storage when we exit.
            let buffer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
            buffer.initialize(to: self._value)
            self.reentrancyBuffer = buffer
            self.reentrancyDepth = 1

            defer {
                // Move the final value out of the temporary buffer and clean up.
                let final = buffer.move()
                buffer.deallocate()
                self.reentrancyBuffer = nil
                self.reentrancyDepth = 0
                self._value = final
                self.didSet?(self._value)
            }

            return try self.callInoutOperation(operation, withPointer: buffer)
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
            if let buffer = self.reentrancyBuffer {
                // If we're currently inside a transaction, update the working
                // buffer so the change is applied to the current transaction.
                buffer.pointee = try newValue()
            } else {
                self._value = try newValue()
                self.didSet?(self._value)
            }
        }
    }

    @inline(__always)
    private func callInoutOperation<T>(
        _ operation: (inout Value) throws -> T,
        withPointer ptr: UnsafeMutablePointer<Value>
    ) rethrows -> T {
        // Reinterpret the `(inout Value) -> T` closure as a pointer-based
        // function so nested (re-entrant) invocations operate on the same
        // working buffer without triggering Swift's inout exclusivity
        // runtime checks. This is an unsafe but controlled technique: the
        // buffer lives for the duration of the outermost transaction.
        return try withoutActuallyEscaping(operation) { op in
            let fn = unsafeBitCast(op, to: ((UnsafeMutablePointer<Value>) throws -> T).self)
            return try fn(ptr)
        }
    }

    deinit {
        // If a working buffer remains allocated for any reason, ensure it is
        // cleaned up to avoid leaking memory.
        if let buffer = self.reentrancyBuffer {
            // If the buffer is still initialized, deinitialize and deallocate.
            // This is conservative and avoids leaking if a transaction was
            // aborted without committing.
            buffer.deinitialize(count: 1)
            buffer.deallocate()
            self.reentrancyBuffer = nil
            self.reentrancyDepth = 0
        }
    }
}

extension LockedValue where Value: Sendable {
    var value: Value {
        self.lock.criticalRegion {
            if let buffer = self.reentrancyBuffer {
                return buffer.pointee
            } else {
                return self._value
            }
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
