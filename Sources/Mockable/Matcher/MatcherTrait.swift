#if DEBUG
#if swift(>=6.1)
import Testing

/// A test trait that provides test-isolated Matcher instances for Swift Testing.
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
    public init() {}
    
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Create a new isolated Matcher for this test
        let isolatedMatcher = Matcher.makeIsolated()
        
        // Execute the test with the isolated matcher
        try await Matcher.$current.withValue(isolatedMatcher) {
            try await function()
        }
    }
}

/// Provides test trait for default container
extension Trait where Self == MatcherTrait {
    /// Provides a test-isolated Matcher instance.
    ///
    /// Use this trait to ensure each test gets its own `Matcher` instance,
    /// preventing race conditions in concurrent tests.
    public static var matcher: Self { Self() }
}

#endif
#endif
