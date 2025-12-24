#if DEBUG
#if swift(>=6.1)
import Mockable
import Testing

/// A test trait that provides a test-isolated Matcher instance.
///
/// ## Usage
///
/// Add the trait to your test suite:
///
/// ```swift
/// @Suite(.matcher)
/// struct MyTests {
///     @Test
///     func myTest() async {
///         // Your test code here
///         // Matcher.register calls will be isolated to this test
///     }
/// }
/// ```
///
/// Or on individual tests:
///
/// ```swift
/// @Test(.matcher)
/// func myTest() async {
///     // Your test code here
/// }
/// ```
public struct MatcherTrait: TestTrait, SuiteTrait, TestScoping {

    private let current: TaskLocal<Matcher>
    private let matcher: Matcher

    public init(current: TaskLocal<Matcher>, matcher: @autoclosure @escaping @Sendable () -> Matcher) {
        self.current = current
        self.matcher = matcher()
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await current.withValue(matcher) {
            try await function()
        }
    }
}

/// Provides test trait for default container
extension Trait where Self == MatcherTrait {
    public static var matcher: MatcherTrait {
        .init(current: Matcher.$current, matcher: .makeIsolated())
    }
}
#endif
#endif
