import Darwin
import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class TerminalInputAndCLITests: XCTestCase {
    func testParserAcceptsOnlyTheThreeExactActions() throws {
        let cases: [(String, ManualVerifierAction)] = [
            ("store-credentials", .storeCredentials),
            ("verify", .verify),
            ("delete-credentials", .deleteCredentials),
        ]

        for (argument, expectedAction) in cases {
            let command = try ManualVerifierCommand.parse(arguments: [argument])
            XCTAssertEqual(command.action, expectedAction)
        }
    }

    func testParserRejectsMissingUnknownAliasedOptionAndCaseChangedActions() {
        let rejectedArguments = [
            [],
            [""],
            ["store"],
            ["delete"],
            ["Store-Credentials"],
            ["VERIFY"],
            ["--verify"],
            ["--help"],
            ["unknown"],
        ]

        for arguments in rejectedArguments {
            assertInvalidCommand(arguments)
        }
    }

    func testParserRejectsEveryExtraPositionalArgument() {
        assertInvalidCommand(["store-credentials", "user@example.com"])
        assertInvalidCommand(["verify", "remote-root"])
        assertInvalidCommand(["delete-credentials", "now"])
    }

    func testEveryActionRequiresAControllingTerminal() {
        XCTAssertTrue(ManualVerifierAction.allCases.allSatisfy(\.requiresControllingTerminal))
    }

    func testConfirmationPoliciesAcceptOnlyExactTokens() {
        XCTAssertTrue(ConfirmationPolicy.overwriteCredentials.accepts("OVERWRITE"))
        XCTAssertTrue(ConfirmationPolicy.deleteCredentials.accepts("DELETE"))

        for rejected in ["", "y", "yes", "overwrite", " OVERWRITE", "OVERWRITE "] {
            XCTAssertFalse(ConfirmationPolicy.overwriteCredentials.accepts(rejected))
        }
        for rejected in ["", "y", "yes", "delete", " DELETE", "DELETE "] {
            XCTAssertFalse(ConfirmationPolicy.deleteCredentials.accepts(rejected))
        }
    }

    func testNonTTYFailsClosedBeforeReadingInput() {
        let device = FakeTerminalDevice(isTerminal: false, input: "secret\n")

        XCTAssertThrowsError(try ControllingTerminal(device: device)) { error in
            XCTAssertEqual(error as? TerminalInputError, .notControllingTerminal)
        }
        XCTAssertEqual(device.readCount, 0)
        XCTAssertTrue(device.writes.isEmpty)
    }

    func testSecretReadDisablesEchoAndRestoresTheCompleteOriginalMode() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(mode: originalMode, input: "application-password\n")
        let terminal = try ControllingTerminal(device: device)

        let value = try terminal.readSecret(prompt: "Application password: ")

        XCTAssertEqual(value, "application-password")
        XCTAssertFalse(device.echoWasEnabledDuringRead)
        XCTAssertEqual(device.appliedModes.count, 2)
        XCTAssertEqual(
            device.appliedModes.first?.localFlags, originalMode.localFlags & ~tcflag_t(ECHO))
        XCTAssertEqual(device.appliedModes.last, originalMode)
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(device.writes, ["Application password: ", "\n"])
    }

    func testSecretReadRestoresTheCompleteOriginalModeAfterReadFailure() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(
            mode: originalMode,
            input: "application-password\n",
            readFailureAt: 1
        )
        let terminal = try ControllingTerminal(device: device)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Application password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .readFailed)
        }
        XCTAssertEqual(device.appliedModes.last, originalMode)
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(device.writes, ["Application password: ", "\n"])
    }

    func testSecretReadRestoresModeWhenInitialEchoDisableFails() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(
            mode: originalMode,
            input: "unused\n",
            failApplyingAt: [1]
        )
        let terminal = try ControllingTerminal(device: device)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Application password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .modeApplyFailed)
        }
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(device.appliedModes, [originalMode])
        XCTAssertTrue(device.writes.isEmpty)
    }

    func testSecretReadDoesNotReturnPasswordWhenModeRestorationFails() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(
            mode: originalMode,
            input: "must-not-escape\n",
            failRestoring: originalMode
        )
        let terminal = try ControllingTerminal(device: device)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Application password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .modeRestoreFailed)
        }
        XCTAssertNotEqual(device.mode, originalMode)
    }

    func testAllProtectedSignalsRestoreBeforePropagationAndRehideIfPropagationReturns() throws {
        XCTAssertEqual(
            TerminalSignal.allCases.map(\.number),
            [SIGINT, SIGTERM, SIGTSTP, SIGHUP, SIGQUIT]
        )

        for signal in TerminalSignal.allCases {
            let recorder = EventRecorder()
            let originalMode = makeDistinctMode()
            let device = FakeTerminalDevice(
                mode: originalMode,
                input: [],
                recorder: recorder
            )
            let signals = FakeTerminalSignalController(
                events: [.signal(signal)] + signalInputEvents("secret\n"),
                recorder: recorder
            )
            let terminal = try ControllingTerminal(device: device, signalController: signals)

            XCTAssertEqual(try terminal.readSecret(prompt: "Password: "), "secret")
            XCTAssertEqual(signals.propagatedSignals, [signal])
            XCTAssertEqual(device.mode, originalMode)
            XCTAssertEqual(signals.installCount, 1)
            XCTAssertEqual(signals.uninstallCount, 1)
            XCTAssertEqual(
                recorder.entries.filter(isModeOrPropagationEvent),
                [
                    "mode:hidden",
                    "mode:original",
                    "propagate:\(signal.number)",
                    "mode:hidden",
                    "mode:original",
                ],
                "unsafe signal ordering for signal \(signal.number)"
            )
            XCTAssertEqual(
                Array(recorder.entries.suffix(2)),
                ["mode:original", "signals:uninstall"],
                "signal monitoring was removed before terminal restoration"
            )
        }
    }

    func testSIGTSTPRestoresSuspendsRehidesAndContinuesReadingAfterResume() throws {
        let recorder = EventRecorder()
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(mode: originalMode, input: [], recorder: recorder)
        let signals = FakeTerminalSignalController(
            events: [
                .byte(UInt8(ascii: "a")),
                .signal(.suspend),
                .byte(UInt8(ascii: "b")),
                .byte(UInt8(ascii: "\n")),
            ],
            recorder: recorder
        )
        let terminal = try ControllingTerminal(device: device, signalController: signals)

        let value = try terminal.readSecret(prompt: "Password: ")

        XCTAssertEqual(value, "ab")
        XCTAssertEqual(signals.propagatedSignals, [.suspend])
        XCTAssertEqual(
            recorder.entries.filter(isModeOrPropagationEvent),
            [
                "mode:hidden",
                "mode:original",
                "propagate:\(SIGTSTP)",
                "mode:hidden",
                "mode:original",
            ]
        )
        XCTAssertEqual(device.mode, originalMode)
    }

    func testSignalWaitFailureRestoresModeAndUninstallsMonitoring() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(mode: originalMode, input: [])
        let signals = FakeTerminalSignalController(
            events: [],
            failNextEventAt: 1
        )
        let terminal = try ControllingTerminal(device: device, signalController: signals)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .readFailed)
        }
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(signals.uninstallCount, 1)
    }

    func testFailureToRestoreBeforeSignalPreventsPropagationAndFinalCleanupRetriesRestore() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(
            mode: originalMode,
            input: [],
            failApplyingAt: [2]
        )
        let signals = FakeTerminalSignalController(events: [.signal(.interrupt)])
        let terminal = try ControllingTerminal(device: device, signalController: signals)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .modeRestoreFailed)
        }
        XCTAssertTrue(signals.propagatedSignals.isEmpty)
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(signals.uninstallCount, 1)
    }

    func testFailureToRehideAfterReturnedSignalRestoresModeAndStopsReading() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(
            mode: originalMode,
            input: [],
            failApplyingAt: [3]
        )
        let signals = FakeTerminalSignalController(
            events: [.signal(.terminate)] + signalInputEvents("must-not-be-read\n")
        )
        let terminal = try ControllingTerminal(device: device, signalController: signals)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .modeApplyFailed)
        }
        XCTAssertEqual(signals.propagatedSignals, [.terminate])
        XCTAssertEqual(signals.nextEventCount, 1)
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(signals.uninstallCount, 1)
    }

    func testSignalPropagationFailureLeavesEchoRestoredAndCleansUp() throws {
        let recorder = EventRecorder()
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(mode: originalMode, input: [], recorder: recorder)
        let signals = FakeTerminalSignalController(
            events: [.signal(.quit)],
            failPropagation: true,
            recorder: recorder
        )
        let terminal = try ControllingTerminal(device: device, signalController: signals)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .readFailed)
        }
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(signals.uninstallCount, 1)
        let filtered = recorder.entries.filter(isModeOrPropagationEvent)
        XCTAssertEqual(
            Array(filtered.prefix(3)),
            [
                "mode:hidden",
                "mode:original",
                "propagate:\(SIGQUIT)",
            ])
    }

    func testSignalUninstallFailureStillRestoresCompleteTerminalMode() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(mode: originalMode, input: [])
        let signals = FakeTerminalSignalController(
            events: signalInputEvents("secret\n"),
            failUninstall: true
        )
        let terminal = try ControllingTerminal(device: device, signalController: signals)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .readFailed)
        }
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertEqual(signals.uninstallCount, 1)
    }

    func testSignalInstallFailureNeverDisablesEcho() throws {
        let originalMode = makeDistinctMode()
        let device = FakeTerminalDevice(mode: originalMode, input: "unused\n")
        let signals = FakeTerminalSignalController(events: [], failInstall: true)
        let terminal = try ControllingTerminal(device: device, signalController: signals)

        XCTAssertThrowsError(try terminal.readSecret(prompt: "Password: ")) { error in
            XCTAssertEqual(error as? TerminalInputError, .readFailed)
        }
        XCTAssertEqual(device.mode, originalMode)
        XCTAssertTrue(device.appliedModes.isEmpty)
        XCTAssertTrue(device.writes.isEmpty)
        XCTAssertEqual(signals.uninstallCount, 0)
    }

    func testLineReaderRejectsEOFNULInvalidUTF8EmptyAndOversizedInput() throws {
        try assertInputError(input: [], expected: .unexpectedEndOfFile)
        try assertInputError(input: [0x00, 0x0A], expected: .embeddedNUL)
        try assertInputError(input: [0xFF, 0x0A], expected: .invalidUTF8)
        try assertInputError(input: [0x0A], expected: .emptyInput)
        try assertInputError(
            input: Array(repeating: UInt8(ascii: "a"), count: 4_097) + [0x0A],
            expected: .inputTooLong
        )
    }

    private func assertInvalidCommand(
        _ arguments: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ManualVerifierCommand.parse(arguments: arguments),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ManualVerifierCommandError,
                .invalidArguments,
                file: file,
                line: line
            )
        }
    }

    private func assertInputError(
        input: [UInt8],
        expected: TerminalInputError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let device = FakeTerminalDevice(input: input)
        let terminal = try ControllingTerminal(device: device)

        XCTAssertThrowsError(
            try terminal.readLine(prompt: "Value: "),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? TerminalInputError, expected, file: file, line: line)
        }
    }

    private func signalInputEvents(_ input: String) -> [TerminalReadEvent] {
        Array(input.utf8).map(TerminalReadEvent.byte)
    }

    private func isModeOrPropagationEvent(_ event: String) -> Bool {
        event.hasPrefix("mode:") || event.hasPrefix("propagate:")
    }

    private func makeDistinctMode() -> TerminalMode {
        TerminalMode(
            inputFlags: 0x11,
            outputFlags: 0x22,
            controlFlags: 0x33,
            localFlags: tcflag_t(ECHO) | 0x44,
            controlCharacters: [0x01, 0x02, 0x03, 0x04],
            inputSpeed: 9_600,
            outputSpeed: 19_200
        )
    }
}

private final class EventRecorder {
    private(set) var entries: [String] = []

    func record(_ event: String) {
        entries.append(event)
    }
}

private enum FakeTerminalFailure: Error {
    case read
    case applyMode
    case signalInstall
    case signalRead
    case signalPropagation
    case signalUninstall
}

private final class FakeTerminalDevice: TerminalDevice {
    let isTerminal: Bool
    private let originalMode: TerminalMode
    private var input: [UInt8]
    private let readFailureAt: Int?
    private let failRestoring: TerminalMode?
    private let failApplyingAt: Set<Int>
    private let recorder: EventRecorder?

    private(set) var mode: TerminalMode
    private(set) var readCount = 0
    private(set) var writes: [String] = []
    private(set) var appliedModes: [TerminalMode] = []
    private(set) var echoWasEnabledDuringRead = false
    private var applyAttemptCount = 0

    init(
        isTerminal: Bool = true,
        mode: TerminalMode = TerminalMode(
            inputFlags: 0,
            outputFlags: 0,
            controlFlags: 0,
            localFlags: tcflag_t(ECHO),
            controlCharacters: [],
            inputSpeed: 0,
            outputSpeed: 0
        ),
        input: String,
        readFailureAt: Int? = nil,
        failRestoring: TerminalMode? = nil,
        failApplyingAt: Set<Int> = [],
        recorder: EventRecorder? = nil
    ) {
        self.isTerminal = isTerminal
        originalMode = mode
        self.mode = mode
        self.input = Array(input.utf8)
        self.readFailureAt = readFailureAt
        self.failRestoring = failRestoring
        self.failApplyingAt = failApplyingAt
        self.recorder = recorder
    }

    convenience init(
        isTerminal: Bool = true,
        mode: TerminalMode = TerminalMode(
            inputFlags: 0,
            outputFlags: 0,
            controlFlags: 0,
            localFlags: tcflag_t(ECHO),
            controlCharacters: [],
            inputSpeed: 0,
            outputSpeed: 0
        ),
        input: [UInt8],
        readFailureAt: Int? = nil,
        failRestoring: TerminalMode? = nil,
        failApplyingAt: Set<Int> = [],
        recorder: EventRecorder? = nil
    ) {
        self.init(
            isTerminal: isTerminal,
            mode: mode,
            input: "",
            readFailureAt: readFailureAt,
            failRestoring: failRestoring,
            failApplyingAt: failApplyingAt,
            recorder: recorder
        )
        self.input = input
    }

    func readByte() throws -> UInt8? {
        readCount += 1
        echoWasEnabledDuringRead =
            echoWasEnabledDuringRead
            || (mode.localFlags & tcflag_t(ECHO)) != 0
        if readFailureAt == readCount {
            throw FakeTerminalFailure.read
        }
        guard !input.isEmpty else { return nil }
        return input.removeFirst()
    }

    func write(_ bytes: [UInt8]) throws {
        writes.append(String(decoding: bytes, as: UTF8.self))
    }

    func readMode() throws -> TerminalMode {
        originalMode
    }

    func applyMode(_ newMode: TerminalMode) throws {
        applyAttemptCount += 1
        recorder?.record(newMode == originalMode ? "mode:original" : "mode:hidden")

        if failApplyingAt.contains(applyAttemptCount) {
            throw FakeTerminalFailure.applyMode
        }
        if let failRestoring, newMode == failRestoring, !appliedModes.isEmpty {
            throw FakeTerminalFailure.applyMode
        }
        mode = newMode
        appliedModes.append(newMode)
    }
}

private final class FakeTerminalSignalController: TerminalSignalController {
    private var events: [TerminalReadEvent]
    private let failInstall: Bool
    private let failNextEventAt: Int?
    private let failPropagation: Bool
    private let failUninstall: Bool
    private let recorder: EventRecorder?

    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    private(set) var nextEventCount = 0
    private(set) var propagatedSignals: [TerminalSignal] = []

    init(
        events: [TerminalReadEvent],
        failInstall: Bool = false,
        failNextEventAt: Int? = nil,
        failPropagation: Bool = false,
        failUninstall: Bool = false,
        recorder: EventRecorder? = nil
    ) {
        self.events = events
        self.failInstall = failInstall
        self.failNextEventAt = failNextEventAt
        self.failPropagation = failPropagation
        self.failUninstall = failUninstall
        self.recorder = recorder
    }

    func install() throws {
        installCount += 1
        recorder?.record("signals:install")
        if failInstall {
            throw FakeTerminalFailure.signalInstall
        }
    }

    func nextEvent() throws -> TerminalReadEvent {
        nextEventCount += 1
        if failNextEventAt == nextEventCount {
            throw FakeTerminalFailure.signalRead
        }
        guard !events.isEmpty else {
            return .endOfFile
        }
        let event = events.removeFirst()
        switch event {
        case .signal(let signal):
            recorder?.record("event:signal:\(signal.number)")
        case .byte:
            recorder?.record("event:byte")
        case .endOfFile:
            recorder?.record("event:eof")
        }
        return event
    }

    func propagate(_ signal: TerminalSignal) throws {
        propagatedSignals.append(signal)
        recorder?.record("propagate:\(signal.number)")
        if failPropagation {
            throw FakeTerminalFailure.signalPropagation
        }
    }

    func uninstall() throws {
        uninstallCount += 1
        recorder?.record("signals:uninstall")
        if failUninstall {
            throw FakeTerminalFailure.signalUninstall
        }
    }
}
