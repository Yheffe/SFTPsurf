import Foundation
import SFTPsurfCore

// SFTPsurf's self-test suite.
//
// Run with `Scripts/test.sh` (or `swift run SelfTest`). Exits non-zero if
// anything fails, so it works in a pre-commit hook or CI step.
Bootstrap.configureProcess()

print("SFTPsurf self-test")
if !RealHostFixture.isConfigured {
    print("(set SFTPsurf_REAL_HOST=<bookmark-uuid> to also test against a real server)")
}
print("")

var cases: [TestCase] = []
cases += RemotePathTests.cases
cases += RemoteEntryTests.cases
cases += ConnectionProfileTests.cases
cases += FormattingTests.cases
cases += ErrorPresentationTests.cases
cases += SFTPClientTests.cases
cases += FTPClientTests.cases
cases += QueueAndStoreTests.cases
cases += LaunchOptionsTests.cases
cases += TransportTests.cases
cases += RealSFTPTests.cases

let exitCode = await TestRunner(cases).run()
exit(exitCode)
