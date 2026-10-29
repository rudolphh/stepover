import XCTest
@testable import StepoverKit

final class InstallWatchTests: XCTestCase {
    private let gb: Int64 = 1_000_000_000
    private let bottle = "/Users/x/Library/Application Support/Stepover/Bottles/Tiny Game"

    private func process(_ pid: Int32, _ path: String) -> RunningPrograms.Process {
        RunningPrograms.Process(pid: pid, windowsPath: path, cwd: bottle + "/drive_c")
    }

    private let setup = #"Z:\Users\x\Downloads\Tiny\setup.exe"#
    private let setupTmp = #"C:\users\crossover\AppData\Local\Temp\is-AB12C.tmp\setup.tmp"#

    private func sample(_ time: Double, written: Int64 = 100, cpu: Double = 0, free: Int64 = 500_000_000_000,
                        processes: [RunningPrograms.Process]? = nil, source: Bool = true) -> InstallSample {
        InstallSample(time: time, processes: processes ?? [process(10, setup)], cpuSeconds: cpu,
                      written: written, free: free, sourceExists: source)
    }

    func testHangProneStepsEndedOnce() {
        var watch = InstallWatch(kind: .inno, visible: false)
        let running = [process(10, setup), process(40, #"C:\Games\Tiny Game\_Redist\vc_redist.x64.exe"#),
                       process(41, #"C:\Games\Tiny Game\_Redist\QuickSFV.EXE"#)]
        XCTAssertEqual(watch.step(sample(0, processes: running)), [.end([40, 41])])
        XCTAssertEqual(watch.step(sample(2, processes: running)), [])
        XCTAssertEqual(watch.step(sample(4, processes: [process(10, setup), process(42, #"C:\x\DXSETUP.exe"#)])), [.end([42])])
    }

    func testLargeAddressFixForInnoOnly() {
        var inno = InstallWatch(kind: .inno, visible: false)
        let running = [process(10, setup), process(7, setupTmp)]
        XCTAssertEqual(inno.step(sample(0, processes: running)), [.largeAddressFix(pid: 7, windowsPath: setupTmp)])
        XCTAssertEqual(inno.step(sample(2, processes: running + [process(8, setupTmp.replacingOccurrences(of: "setup.tmp", with: "setup-stepover.tmp"))])), [])
        var nsis = InstallWatch(kind: .nsis, visible: false)
        XCTAssertEqual(nsis.step(sample(0, processes: running)), [])
    }

    func testDiskFloorPausesAndResumes() {
        var watch = InstallWatch(kind: .inno, visible: false)
        XCTAssertEqual(watch.step(sample(0, free: 20 * gb)), [])
        XCTAssertEqual(watch.step(sample(2, free: 4 * gb)), [.pause([10])])
        XCTAssertEqual(watch.step(sample(4, free: 8 * gb)), [])
        XCTAssertEqual(watch.step(sample(6, free: 11 * gb)), [.resume([10])])
        var low = InstallWatch(kind: .nsis, visible: false)
        XCTAssertEqual(low.step(sample(0, free: 3 * gb)), [.pause([10])])
    }

    func testStuckIdle() {
        var watch = InstallWatch(kind: .inno, visible: false)
        XCTAssertEqual(watch.step(sample(0)), [])
        XCTAssertEqual(watch.step(sample(300, cpu: 1)), [])
        XCTAssertEqual(watch.step(sample(600, cpu: 2)), [.stuck])
        XCTAssertEqual(watch.step(sample(630, cpu: 2)), [])

        var growing = InstallWatch(kind: .inno, visible: false)
        _ = growing.step(sample(0))
        XCTAssertEqual(growing.step(sample(599, written: 200)), [])
        XCTAssertEqual(growing.step(sample(1_000, written: 200)), [])
        XCTAssertEqual(growing.step(sample(1_199, written: 200)), [.stuck])
    }

    func testStuckBusy() {
        var watch = InstallWatch(kind: .inno, visible: false)
        _ = watch.step(sample(0))
        XCTAssertEqual(watch.step(sample(600, cpu: 600)), [])      // a whole core busy: not idle
        XCTAssertEqual(watch.step(sample(1_799, cpu: 1_799)), [])
        XCTAssertEqual(watch.step(sample(1_800, cpu: 1_800)), [.stuck])
    }

    func testPausedAndVisibleNeverStuck() {
        var visible = InstallWatch(kind: .other, visible: true)
        _ = visible.step(sample(0))
        XCTAssertEqual(visible.step(sample(5_000)), [])

        var paused = InstallWatch(kind: .inno, visible: false)
        XCTAssertEqual(paused.step(sample(0, free: 4 * gb)), [.pause([10])])
        XCTAssertEqual(paused.step(sample(3_000, free: 4 * gb)), [])
        XCTAssertEqual(paused.step(sample(3_002, free: 11 * gb)), [.resume([10])])
        XCTAssertEqual(paused.step(sample(3_500, free: 11 * gb)), [])
        XCTAssertEqual(paused.step(sample(3_602, free: 11 * gb)), [.stuck])
    }

    func testSourceGone() {
        var watch = InstallWatch(kind: .inno, visible: false)
        XCTAssertEqual(watch.step(sample(0, source: false)), [.sourceGone])
        XCTAssertEqual(watch.step(sample(2, source: false)), [])
    }

    func testStageText() {
        XCTAssertEqual(InstallStage.waiting.text, "Waiting to install")
        XCTAssertEqual(InstallStage.alreadyInLibrary("x").text, "Already in your Library")
        XCTAssertEqual(InstallStage.gettingReady.text, "Getting ready")
        XCTAssertEqual(InstallStage.copying(done: 12 * gb, total: 40 * gb).text, "Copying, 12 GB of 40 GB")
        XCTAssertEqual(InstallStage.copying(done: 3_000_000, total: 5_000_000).text, "Copying")
        XCTAssertEqual(InstallStage.installing(written: 12 * gb).text, "Installing (12 GB so far)")
        XCTAssertEqual(InstallStage.installing(written: 300_000_000).text, "Installing")
        XCTAssertEqual(InstallStage.needsYou.text, "The installer needs you: it's open on the Mac")
        XCTAssertEqual(InstallStage.addingComponents.text, "Adding what the game needs")
        XCTAssertEqual(InstallStage.findingGame.text, "Finding the game")
        XCTAssertEqual(InstallStage.paused.text, "Paused: the disk is nearly full. Free up some space and it carries on.")
        XCTAssertEqual(InstallStage.failed(.installerError("Unarc.dll returned an error code: -11")).text,
                       "The installer stopped with an error: Unarc.dll returned an error code: -11.")
        XCTAssertEqual(InstallStage.failed(.installerError("The source file is corrupted.")).text,
                       "The installer stopped with an error: The source file is corrupted.")
        XCTAssertEqual(InstallStage.failed(.installerError(nil)).text, "The installer stopped with an error.")
        XCTAssertEqual(InstallStage.failed(.damaged).text, "Some of the installer's files are damaged. Download them again, then Try Again.")
        XCTAssertEqual(InstallStage.failed(.stoppedResponding).text, "The installer stopped responding.")
        XCTAssertEqual(InstallStage.failed(.noGame).text, "Installed, but Stepover couldn't tell which program is the game.")
        XCTAssertEqual(InstallStage.failed(.nothing).text, "This folder doesn't have an installer or a game in it.")
        XCTAssertEqual(InstallStage.failed(.folderGone).text, "The folder isn't there anymore.")
        XCTAssertEqual(InstallStage.failed(.archive).text, "Unpack it first, then drag in the folder.")
        XCTAssertEqual(InstallStage.failed(.stillDownloading).text, "This folder is still downloading. Try Again when it's done.")
        XCTAssertEqual(InstallStage.failed(.interrupted).text, "Interrupted")
        XCTAssertEqual(InstallStage.done(addOnFailed: "Extra").text, "Ready; the Extra add-on didn't install")
        XCTAssertEqual(InstallStage.done(addOnFailed: nil).text, "Ready")
        XCTAssertTrue(InstallStage.paused.isActive)
        XCTAssertTrue(InstallStage.installing(written: 0).isActive)
        XCTAssertFalse(InstallStage.waiting.isActive)
        XCTAssertFalse(InstallStage.failed(.damaged).isActive)
    }

    func testArgumentsAndCPU() {
        XCTAssertEqual(RunningPrograms.arguments(getpid()), CommandLine.arguments)
        XCTAssertGreaterThan(RunningPrograms.cpuSeconds(getpid()), 0)
        XCTAssertEqual(RunningPrograms.arguments(-1), [])
    }
}
