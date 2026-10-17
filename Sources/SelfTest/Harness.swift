import Foundation

/// A failed expectation. Carries the source location so the runner can point at
/// the exact line that broke.
struct CheckError: Error, CustomStringConvertible {
    let message: String
    let file: String
    let line: Int

    var description: String { "\(message)  (\(file):\(line))" }
}

func expect(
    _ condition: Bool,
    _ message: String = "expectation failed",
    file: String = #fileID,
    line: Int = #line
) throws {
    if !condition { throw CheckError(message: message, file: file, line: line) }
}

func require<T>(
    _ value: T?,
    _ message: String = "required a value but got nil",
    file: String = #fileID,
    line: Int = #line
) throws -> T {
    guard let value else { throw CheckError(message: message, file: file, line: line) }
    return value
}

/// Asserts that `body` throws. A `CheckError` from inside the block is rethrown
/// rather than swallowed, so a failing expectation inside a throwing block is
/// still reported as a failure.
func expectThrows(
    _ message: String = "expected an error but none was thrown",
    file: String = #fileID,
    line: Int = #line,
    _ body: () async throws -> Void
) async throws {
    do {
        try await body()
    } catch let error as CheckError {
        throw error
    } catch {
        return
    }
    throw CheckError(message: message, file: file, line: line)
}

/// Thrown to mark a test as not applicable on this machine.
struct SkipError: Error {
    let message: String
}

func skip(_ message: String) throws -> Never {
    throw SkipError(message: message)
}

/// One named test.
struct TestCase {
    let name: String
    let body: () async throws -> Void

    init(_ name: String, _ body: @escaping () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

/// Runs cases in order and reports a summary. Sequential execution keeps the
/// output readable and avoids spawning many helper processes at once.
struct TestRunner {
    private let cases: [TestCase]

    init(_ cases: [TestCase]) {
        self.cases = cases
    }

    /// Returns the process exit code.
    func run() async -> Int32 {
        var passed = 0
        var skipped = 0
        var failures: [(name: String, error: String)] = []

        let started = Date()
        for testCase in cases {
            do {
                try await testCase.body()
                passed += 1
                print("  ✅ \(testCase.name)")
            } catch let error as SkipError {
                skipped += 1
                print("  ⏭️  \(testCase.name) — \(error.message)")
            } catch let error as CheckError {
                failures.append((testCase.name, error.description))
                print("  ❌ \(testCase.name)\n       \(error.description)")
            } catch {
                failures.append((testCase.name, "\(error)"))
                print("  ❌ \(testCase.name)\n       \(error)")
            }
        }

        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("")
        print("\(passed) passed, \(failures.count) failed, \(skipped) skipped  (\(elapsed))")

        for failure in failures {
            print("  ✗ \(failure.name): \(failure.error)")
        }

        return failures.isEmpty ? 0 : 1
    }
}
