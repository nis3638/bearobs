import Darwin
import Foundation

public enum ManualVerifierAction: String, CaseIterable, Equatable, Sendable {
    case storeCredentials = "store-credentials"
    case verify = "verify"
    case deleteCredentials = "delete-credentials"

    public var requiresControllingTerminal: Bool { true }
}

public struct ManualVerifierCommand: Equatable, Sendable {
    public let action: ManualVerifierAction

    public init(action: ManualVerifierAction) {
        self.action = action
    }

    public static func parse(arguments: [String]) throws -> ManualVerifierCommand {
        guard arguments.count == 1,
            let action = ManualVerifierAction(rawValue: arguments[0])
        else {
            throw ManualVerifierCommandError.invalidArguments
        }
        return ManualVerifierCommand(action: action)
    }
}

public enum ManualVerifierCommandError: Error, Equatable, Sendable {
    case invalidArguments
}

public enum ConfirmationPolicy: Equatable, Sendable {
    case overwriteCredentials
    case deleteCredentials

    public func accepts(_ input: String) -> Bool {
        switch self {
        case .overwriteCredentials:
            input == "OVERWRITE"
        case .deleteCredentials:
            input == "DELETE"
        }
    }
}

public enum TerminalInputError: Error, Equatable, Sendable {
    case openFailed
    case notControllingTerminal
    case readFailed
    case writeFailed
    case modeReadFailed
    case modeApplyFailed
    case modeRestoreFailed
    case unexpectedEndOfFile
    case embeddedNUL
    case invalidUTF8
    case emptyInput
    case inputTooLong
    case signalMonitoringUnavailable(Int32)
}

public struct TerminalMode: Equatable, Sendable {
    public let inputFlags: tcflag_t
    public let outputFlags: tcflag_t
    public let controlFlags: tcflag_t
    public let localFlags: tcflag_t
    public let controlCharacters: [cc_t]
    public let inputSpeed: speed_t
    public let outputSpeed: speed_t

    public init(
        inputFlags: tcflag_t,
        outputFlags: tcflag_t,
        controlFlags: tcflag_t,
        localFlags: tcflag_t,
        controlCharacters: [cc_t],
        inputSpeed: speed_t,
        outputSpeed: speed_t
    ) {
        self.inputFlags = inputFlags
        self.outputFlags = outputFlags
        self.controlFlags = controlFlags
        self.localFlags = localFlags
        self.controlCharacters = controlCharacters
        self.inputSpeed = inputSpeed
        self.outputSpeed = outputSpeed
    }

    fileprivate init(attributes: termios) {
        inputFlags = attributes.c_iflag
        outputFlags = attributes.c_oflag
        controlFlags = attributes.c_cflag
        localFlags = attributes.c_lflag
        controlCharacters = withUnsafeBytes(of: attributes.c_cc) { bytes in
            bytes.map { cc_t($0) }
        }
        inputSpeed = attributes.c_ispeed
        outputSpeed = attributes.c_ospeed
    }

    fileprivate var withoutEcho: TerminalMode {
        TerminalMode(
            inputFlags: inputFlags,
            outputFlags: outputFlags,
            controlFlags: controlFlags,
            localFlags: localFlags & ~tcflag_t(ECHO),
            controlCharacters: controlCharacters,
            inputSpeed: inputSpeed,
            outputSpeed: outputSpeed
        )
    }

    fileprivate func makeAttributes() -> termios {
        var attributes = termios()
        attributes.c_iflag = inputFlags
        attributes.c_oflag = outputFlags
        attributes.c_cflag = controlFlags
        attributes.c_lflag = localFlags
        attributes.c_ispeed = inputSpeed
        attributes.c_ospeed = outputSpeed
        withUnsafeMutableBytes(of: &attributes.c_cc) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            let count = min(bytes.count, controlCharacters.count)
            for index in 0..<count {
                bytes[index] = UInt8(controlCharacters[index])
            }
        }
        return attributes
    }
}

public protocol TerminalDevice: AnyObject {
    var isTerminal: Bool { get }

    func readByte() throws -> UInt8?
    func write(_ bytes: [UInt8]) throws
    func readMode() throws -> TerminalMode
    func applyMode(_ mode: TerminalMode) throws
}

enum TerminalSignal: CaseIterable, Equatable, Hashable, Sendable {
    case interrupt
    case terminate
    case suspend
    case hangup
    case quit

    var number: Int32 {
        switch self {
        case .interrupt:
            SIGINT
        case .terminate:
            SIGTERM
        case .suspend:
            SIGTSTP
        case .hangup:
            SIGHUP
        case .quit:
            SIGQUIT
        }
    }

    fileprivate init?(number: Int32) {
        switch number {
        case SIGINT:
            self = .interrupt
        case SIGTERM:
            self = .terminate
        case SIGTSTP:
            self = .suspend
        case SIGHUP:
            self = .hangup
        case SIGQUIT:
            self = .quit
        default:
            return nil
        }
    }
}

enum TerminalReadEvent: Equatable, Sendable {
    case byte(UInt8)
    case endOfFile
    case signal(TerminalSignal)
}

protocol TerminalSignalController: AnyObject {
    func install() throws
    func nextEvent() throws -> TerminalReadEvent
    func propagate(_ signal: TerminalSignal) throws
    func uninstall() throws
}

private final class DirectTerminalSignalController: TerminalSignalController {
    private let device: any TerminalDevice

    init(device: any TerminalDevice) {
        self.device = device
    }

    func install() throws {}

    func nextEvent() throws -> TerminalReadEvent {
        guard let byte = try device.readByte() else {
            return .endOfFile
        }
        return .byte(byte)
    }

    func propagate(_ signal: TerminalSignal) throws {
        // This controller is used only for explicitly injected terminal devices.
        // It never changes process signal state or sends a real signal.
        _ = signal
    }

    func uninstall() throws {}
}

public final class ControllingTerminal {
    public static let maximumInputBytes = 4_096

    private let device: any TerminalDevice
    private let signalController: any TerminalSignalController

    public convenience init() throws {
        let device: POSIXTerminalDevice
        do {
            device = try POSIXTerminalDevice.openControllingTerminal()
        } catch {
            throw TerminalInputError.openFailed
        }
        try self.init(
            device: device,
            signalController: KqueueTerminalSignalController(device: device)
        )
    }

    public convenience init(device: any TerminalDevice) throws {
        try self.init(
            device: device,
            signalController: DirectTerminalSignalController(device: device)
        )
    }

    init(
        device: any TerminalDevice,
        signalController: any TerminalSignalController
    ) throws {
        guard device.isTerminal else {
            throw TerminalInputError.notControllingTerminal
        }
        self.device = device
        self.signalController = signalController
    }

    public func readLine(prompt: String) throws -> String {
        try readValidatedLine(prompt: prompt) {
            try self.device.readByte()
        }
    }

    public func readSecret(prompt: String) throws -> String {
        let originalMode: TerminalMode
        do {
            originalMode = try device.readMode()
        } catch {
            throw TerminalInputError.modeReadFailed
        }

        do {
            try signalController.install()
        } catch let error as KqueueTerminalSignalControllerError {
            throw TerminalInputError.signalMonitoringUnavailable(error.systemErrorCode)
        } catch {
            // install() owns its rollback. ECHO has not been disabled yet, and
            // uninstall() must not be called for a controller that never installed.
            throw TerminalInputError.readFailed
        }

        let hiddenMode = originalMode.withoutEcho
        let operation: Result<String, TerminalInputError>
        do {
            try device.applyMode(hiddenMode)
            operation = readSecretLine(
                prompt: prompt,
                originalMode: originalMode,
                hiddenMode: hiddenMode
            )
        } catch {
            operation = .failure(.modeApplyFailed)
        }

        // Security-sensitive ordering: terminal restoration always precedes
        // restoration/removal of process signal monitoring.
        var restorationFailed = false
        do {
            try device.applyMode(originalMode)
        } catch {
            restorationFailed = true
        }

        var uninstallFailed = false
        do {
            try signalController.uninstall()
        } catch {
            uninstallFailed = true
        }

        guard !restorationFailed else {
            throw TerminalInputError.modeRestoreFailed
        }
        guard !uninstallFailed else {
            throw TerminalInputError.readFailed
        }
        return try operation.get()
    }

    private func readSecretLine(
        prompt: String,
        originalMode: TerminalMode,
        hiddenMode: TerminalMode
    ) -> Result<String, TerminalInputError> {
        var operation: Result<String, TerminalInputError>
        do {
            operation = .success(
                try readValidatedLine(prompt: prompt) {
                    try self.nextSecretByte(
                        originalMode: originalMode,
                        hiddenMode: hiddenMode
                    )
                }
            )
        } catch let error as TerminalInputError {
            operation = .failure(error)
        } catch {
            operation = .failure(.readFailed)
        }

        do {
            try write([UInt8(ascii: "\n")])
        } catch let error as TerminalInputError {
            if case .success = operation {
                operation = .failure(error)
            }
        } catch {
            if case .success = operation {
                operation = .failure(.writeFailed)
            }
        }
        return operation
    }

    private func nextSecretByte(
        originalMode: TerminalMode,
        hiddenMode: TerminalMode
    ) throws -> UInt8? {
        while true {
            let event: TerminalReadEvent
            do {
                event = try signalController.nextEvent()
            } catch {
                throw TerminalInputError.readFailed
            }

            switch event {
            case .byte(let byte):
                return byte
            case .endOfFile:
                return nil
            case .signal(let signal):
                try propagateSignal(
                    signal,
                    originalMode: originalMode,
                    hiddenMode: hiddenMode
                )
            }
        }
    }

    private func propagateSignal(
        _ signal: TerminalSignal,
        originalMode: TerminalMode,
        hiddenMode: TerminalMode
    ) throws {
        do {
            try device.applyMode(originalMode)
        } catch {
            // Do not propagate while ECHO may still be disabled. Final cleanup
            // will make one more restoration attempt.
            throw TerminalInputError.modeRestoreFailed
        }

        do {
            try signalController.propagate(signal)
        } catch {
            // ECHO is already restored and remains restored on this path.
            throw TerminalInputError.readFailed
        }

        // A terminating signal never returns. SIGTSTP returns here only after
        // SIGCONT, at which point password entry must become hidden again.
        do {
            try device.applyMode(hiddenMode)
        } catch {
            throw TerminalInputError.modeApplyFailed
        }
    }

    private func readValidatedLine(
        prompt: String,
        nextByte: () throws -> UInt8?
    ) throws -> String {
        try write(Array(prompt.utf8))

        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)

        while true {
            let byte: UInt8
            do {
                guard let nextByte = try nextByte() else {
                    throw TerminalInputError.unexpectedEndOfFile
                }
                byte = nextByte
            } catch let error as TerminalInputError {
                throw error
            } catch {
                throw TerminalInputError.readFailed
            }

            if byte == UInt8(ascii: "\n") {
                break
            }
            guard byte != 0 else {
                throw TerminalInputError.embeddedNUL
            }
            guard bytes.count < Self.maximumInputBytes else {
                throw TerminalInputError.inputTooLong
            }
            bytes.append(byte)
        }

        guard !bytes.isEmpty else {
            throw TerminalInputError.emptyInput
        }
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw TerminalInputError.invalidUTF8
        }
        return value
    }

    private func write(_ bytes: [UInt8]) throws {
        do {
            try device.write(bytes)
        } catch {
            throw TerminalInputError.writeFailed
        }
    }
}

private enum KqueueTerminalSignalControllerError: Error {
    case invalidState
    case systemCall(Int32)

    var systemErrorCode: Int32 {
        switch self {
        case .invalidState:
            EINVAL
        case .systemCall(let code):
            code
        }
    }
}

/// Signal monitoring without a language-level signal handler.
///
/// EVFILT_SIGNAL records delivery attempts while the dispositions are SIG_IGN,
/// so no Swift code, allocation, locking, ARC, or runtime operation executes in
/// an asynchronous signal context. All terminal restoration and propagation run
/// later in ordinary synchronous control flow.
private final class KqueueTerminalSignalController: TerminalSignalController {
    private let device: POSIXTerminalDevice
    private var queueDescriptor: Int32 = -1
    private var savedActions: [Int32: sigaction] = [:]
    private var registeredSignals: Set<TerminalSignal> = []
    private var installed = false

    init(device: POSIXTerminalDevice) {
        self.device = device
    }

    deinit {
        restoreSavedActionsBestEffort()
        closeQueueBestEffort()
    }

    func install() throws {
        guard !installed, queueDescriptor < 0, savedActions.isEmpty else {
            throw KqueueTerminalSignalControllerError.invalidState
        }

        let descriptor = Darwin.kqueue()
        guard descriptor >= 0 else {
            throw KqueueTerminalSignalControllerError.systemCall(errno)
        }
        queueDescriptor = descriptor

        do {
            // Read every disposition before changing any of them. This makes a
            // partial setup failure straightforward to roll back.
            for signal in TerminalSignal.allCases {
                savedActions[signal.number] = try readAction(for: signal)
            }

            for signal in TerminalSignal.allCases {
                var signalFilter = [
                    makeSignalFilter(signal, flags: UInt16(EV_ADD | EV_ENABLE))
                ]
                try submit(changes: &signalFilter)
                registeredSignals.insert(signal)
            }

            for signal in TerminalSignal.allCases {
                try setIgnored(signal)
            }
            installed = true
        } catch {
            restoreSavedActionsBestEffort()
            closeQueueBestEffort()
            registeredSignals.removeAll()
            installed = false
            throw error
        }
    }

    func nextEvent() throws -> TerminalReadEvent {
        guard installed, queueDescriptor >= 0 else {
            throw KqueueTerminalSignalControllerError.invalidState
        }

        while true {
            var readSet = try makeDescriptorSet([
                queueDescriptor,
                device.fileDescriptor,
            ])
            let highestDescriptor = max(queueDescriptor, device.fileDescriptor)
            let count = Darwin.select(highestDescriptor + 1, &readSet, nil, nil, nil)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw KqueueTerminalSignalControllerError.systemCall(errno)
            }
            guard count > 0 else {
                continue
            }

            if descriptorSetContains(queueDescriptor, in: readSet) {
                return try dequeueSignal()
            }

            guard descriptorSetContains(device.fileDescriptor, in: readSet) else {
                continue
            }
            guard let byte = try device.readByte() else {
                return .endOfFile
            }
            return .byte(byte)
        }
    }

    private func dequeueSignal() throws -> TerminalReadEvent {
        var event = kevent()
        let count = kevent(
            queueDescriptor,
            nil,
            0,
            &event,
            1,
            nil
        )

        guard count == 1 else {
            if count < 0 {
                throw KqueueTerminalSignalControllerError.systemCall(errno)
            }
            throw KqueueTerminalSignalControllerError.systemCall(EIO)
        }
        guard event.flags & UInt16(EV_ERROR) == 0 else {
            throw KqueueTerminalSignalControllerError.systemCall(Int32(event.data))
        }
        guard event.filter == Int16(EVFILT_SIGNAL),
            let signal = TerminalSignal(number: Int32(event.ident))
        else {
            throw KqueueTerminalSignalControllerError.systemCall(EINVAL)
        }
        return .signal(signal)
    }

    private func makeDescriptorSet(_ descriptors: [Int32]) throws -> fd_set {
        var set = fd_set()
        try withUnsafeMutableBytes(of: &set) { rawBuffer in
            let words = rawBuffer.bindMemory(to: UInt32.self)
            let capacity = words.count * UInt32.bitWidth
            for descriptor in descriptors {
                guard descriptor >= 0, Int(descriptor) < capacity else {
                    throw KqueueTerminalSignalControllerError.systemCall(EINVAL)
                }
                let wordIndex = Int(descriptor) / UInt32.bitWidth
                let bitIndex = UInt32(Int(descriptor) % UInt32.bitWidth)
                words[wordIndex] |= UInt32(1) << bitIndex
            }
        }
        return set
    }

    private func descriptorSetContains(_ descriptor: Int32, in set: fd_set) -> Bool {
        guard descriptor >= 0 else {
            return false
        }
        var set = set
        return withUnsafeBytes(of: &set) { rawBuffer in
            let words = rawBuffer.bindMemory(to: UInt32.self)
            let wordIndex = Int(descriptor) / UInt32.bitWidth
            guard wordIndex < words.count else {
                return false
            }
            let bitIndex = UInt32(Int(descriptor) % UInt32.bitWidth)
            return words[wordIndex] & (UInt32(1) << bitIndex) != 0
        }
    }

    func propagate(_ signal: TerminalSignal) throws {
        guard installed,
            queueDescriptor >= 0,
            let savedAction = savedActions[signal.number]
        else {
            throw KqueueTerminalSignalControllerError.invalidState
        }

        // Remove the filter before self-delivery. Otherwise kill() would enqueue
        // the same signal again and the next read would propagate it twice.
        if registeredSignals.contains(signal) {
            var deletion = [makeSignalFilter(signal, flags: UInt16(EV_DELETE))]
            try submit(changes: &deletion)
            registeredSignals.remove(signal)
        }

        try writeAction(savedAction, for: signal)

        guard Darwin.kill(Darwin.getpid(), signal.number) == 0 else {
            throw KqueueTerminalSignalControllerError.systemCall(errno)
        }

        // A default terminating action never reaches here. A default SIGTSTP
        // reaches here after SIGCONT. Capture handler/SA_RESETHAND changes so
        // uninstall restores the disposition that propagation actually left.
        let actionAfterPropagation: sigaction
        do {
            actionAfterPropagation = try readAction(for: signal)
        } catch {
            // The current disposition is already the post-propagation one. Do
            // not later overwrite it with the stale pre-propagation snapshot.
            savedActions.removeValue(forKey: signal.number)
            throw error
        }
        savedActions[signal.number] = actionAfterPropagation

        // Ignore before re-registering the filter. This avoids a window in
        // which a second delivery could run the restored disposition before
        // EVFILT_SIGNAL is ready to capture it.
        try setIgnored(signal)
        var addition = [
            makeSignalFilter(signal, flags: UInt16(EV_ADD | EV_ENABLE))
        ]
        try submit(changes: &addition)
        registeredSignals.insert(signal)
    }

    func uninstall() throws {
        guard installed, queueDescriptor >= 0 else {
            throw KqueueTerminalSignalControllerError.invalidState
        }

        // Restore dispositions before closing the kqueue. A signal racing with
        // teardown then follows its real action exactly once; any kqueue record
        // is discarded when the descriptor closes.
        let restoredAllActions = restoreSavedActionsBestEffort()
        let closedQueue = closeQueueBestEffort()
        registeredSignals.removeAll()
        installed = false

        guard restoredAllActions, closedQueue else {
            throw KqueueTerminalSignalControllerError.systemCall(errno)
        }
    }

    private func readAction(for signal: TerminalSignal) throws -> sigaction {
        var action = sigaction()
        guard sigaction(signal.number, nil, &action) == 0 else {
            throw KqueueTerminalSignalControllerError.systemCall(errno)
        }
        return action
    }

    private func writeAction(
        _ action: sigaction,
        for signal: TerminalSignal
    ) throws {
        var mutableAction = action
        guard sigaction(signal.number, &mutableAction, nil) == 0 else {
            throw KqueueTerminalSignalControllerError.systemCall(errno)
        }
    }

    private func setIgnored(_ signal: TerminalSignal) throws {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = SIG_IGN
        guard Darwin.sigemptyset(&action.sa_mask) == 0 else {
            throw KqueueTerminalSignalControllerError.systemCall(errno)
        }
        action.sa_flags = 0
        try writeAction(action, for: signal)
    }

    private func submit(changes: inout [kevent]) throws {
        guard queueDescriptor >= 0 else {
            throw KqueueTerminalSignalControllerError.invalidState
        }
        let result = changes.withUnsafeBufferPointer { buffer in
            kevent(
                queueDescriptor,
                buffer.baseAddress,
                Int32(buffer.count),
                nil,
                0,
                nil
            )
        }
        guard result == 0 else {
            throw KqueueTerminalSignalControllerError.systemCall(errno)
        }
    }

    private func makeSignalFilter(
        _ signal: TerminalSignal,
        flags: UInt16
    ) -> kevent {
        var event = kevent()
        event.ident = UInt(signal.number)
        event.filter = Int16(EVFILT_SIGNAL)
        event.flags = flags
        event.fflags = 0
        event.data = 0
        event.udata = nil
        return event
    }

    @discardableResult
    private func restoreSavedActionsBestEffort() -> Bool {
        var restoredAll = true
        for signal in TerminalSignal.allCases {
            guard let action = savedActions[signal.number] else {
                continue
            }
            do {
                try writeAction(action, for: signal)
                savedActions.removeValue(forKey: signal.number)
            } catch {
                restoredAll = false
            }
        }
        return restoredAll
    }

    @discardableResult
    private func closeQueueBestEffort() -> Bool {
        guard queueDescriptor >= 0 else {
            return true
        }
        let descriptor = queueDescriptor
        queueDescriptor = -1
        return Darwin.close(descriptor) == 0
    }
}

private enum POSIXTerminalDeviceError: Error {
    case open
    case read
    case write
    case readMode
    case applyMode
}

private final class POSIXTerminalDevice: TerminalDevice {
    fileprivate let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = Darwin.close(fileDescriptor)
    }

    static func openControllingTerminal() throws -> POSIXTerminalDevice {
        let flags = O_RDWR | O_CLOEXEC | O_NOCTTY
        var descriptor: Int32
        repeat {
            descriptor = Darwin.open("/dev/tty", flags)
        } while descriptor < 0 && errno == EINTR

        guard descriptor >= 0 else {
            throw POSIXTerminalDeviceError.open
        }
        return POSIXTerminalDevice(fileDescriptor: descriptor)
    }

    var isTerminal: Bool {
        Darwin.isatty(fileDescriptor) == 1
    }

    func readByte() throws -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count == 1 {
                return byte
            }
            if count == 0 {
                return nil
            }
            if errno != EINTR {
                throw POSIXTerminalDeviceError.read
            }
        }
    }

    func write(_ bytes: [UInt8]) throws {
        var offset = 0
        try bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < rawBuffer.count {
                let address = baseAddress.advanced(by: offset)
                let count = Darwin.write(fileDescriptor, address, rawBuffer.count - offset)
                if count > 0 {
                    offset += count
                } else if count == 0 || errno != EINTR {
                    throw POSIXTerminalDeviceError.write
                }
            }
        }
    }

    func readMode() throws -> TerminalMode {
        var attributes = termios()
        while true {
            if Darwin.tcgetattr(fileDescriptor, &attributes) == 0 {
                return TerminalMode(attributes: attributes)
            }
            if errno != EINTR {
                throw POSIXTerminalDeviceError.readMode
            }
        }
    }

    func applyMode(_ mode: TerminalMode) throws {
        var attributes = mode.makeAttributes()
        while true {
            if Darwin.tcsetattr(fileDescriptor, TCSAFLUSH, &attributes) == 0 {
                return
            }
            if errno != EINTR {
                throw POSIXTerminalDeviceError.applyMode
            }
        }
    }
}
