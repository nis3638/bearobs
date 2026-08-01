import Darwin
import Foundation

typealias AtomicWriteCall = (Int32, UnsafeRawPointer?, Int) -> Int

final class POSIXAtomicFileOperations: AtomicFileOperations {
    private let writeCall: AtomicWriteCall

    init(
        writeCall: @escaping AtomicWriteCall = { descriptor, buffer, count in
            Darwin.write(descriptor, buffer, count)
        }
    ) {
        self.writeCall = writeCall
    }

    func openDirectory(at path: String) throws -> Int32 {
        let descriptor = open(
            path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw AtomicPOSIXError(code: errno)
        }
        return descriptor
    }

    func existingRegularFile(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> AtomicExistingFile {
        let information = try status(
            named: name,
            in: directoryDescriptor
        )
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw AtomicPOSIXError(code: EFTYPE)
        }
        return AtomicExistingFile(
            permissions: UInt16(information.st_mode & 0o777),
            identity: identity(of: information)
        )
    }

    func openExclusiveStaging(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> AtomicStagingFile {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw AtomicPOSIXError(code: errno)
        }
        do {
            var information = stat()
            guard fstat(descriptor, &information) == 0 else {
                throw AtomicPOSIXError(code: errno)
            }
            return AtomicStagingFile(
                descriptor: descriptor,
                identity: identity(of: information)
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let result = writeCall(
                    descriptor,
                    buffer.baseAddress?.advanced(by: written),
                    buffer.count - written
                )
                if result < 0 {
                    guard errno == EINTR else {
                        throw AtomicPOSIXError(code: errno)
                    }
                    continue
                }
                guard result > 0 else {
                    throw AtomicPOSIXError(code: EIO)
                }
                written += result
            }
        }
    }

    func setPermissions(_ permissions: UInt16, of descriptor: Int32) throws {
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw AtomicPOSIXError(code: errno)
        }
    }

    func synchronizeFile(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else {
            throw AtomicPOSIXError(code: errno)
        }
    }

    func closeFile(_ descriptor: Int32) throws {
        guard Darwin.close(descriptor) == 0 else {
            throw AtomicPOSIXError(code: errno)
        }
    }

    func publish(
        stagingName: String,
        stagingIdentity: AtomicFileIdentity,
        destinationName: String,
        destinationIdentity: AtomicFileIdentity,
        in directoryDescriptor: Int32
    ) throws {
        try requireIdentity(
            stagingIdentity,
            named: stagingName,
            in: directoryDescriptor
        )
        try requireIdentity(
            destinationIdentity,
            named: destinationName,
            in: directoryDescriptor
        )
        guard
            renameat(
                directoryDescriptor,
                stagingName,
                directoryDescriptor,
                destinationName
            ) == 0
        else {
            throw AtomicPOSIXError(code: errno)
        }
    }

    func synchronizeDirectory(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else {
            throw AtomicPOSIXError(code: errno)
        }
    }

    func readFile(
        named name: String,
        expectedIdentity: AtomicFileIdentity,
        expectedByteCount: Int,
        in directoryDescriptor: Int32
    ) throws -> Data {
        let descriptor = openat(
            directoryDescriptor,
            name,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw AtomicPOSIXError(code: errno)
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0 else {
            throw AtomicPOSIXError(code: errno)
        }
        guard information.st_mode & S_IFMT == S_IFREG else {
            throw AtomicPOSIXError(code: EFTYPE)
        }
        guard identity(of: information) == expectedIdentity else {
            throw AtomicPOSIXError(code: ESTALE)
        }
        guard information.st_size == expectedByteCount else {
            throw AtomicPOSIXError(code: EIO)
        }
        return try readAll(
            from: descriptor,
            maximumByteCount: expectedByteCount
        )
    }

    func removeOwnedStaging(
        named name: String,
        identity expectedIdentity: AtomicFileIdentity,
        in directoryDescriptor: Int32
    ) throws {
        let information: stat
        do {
            information = try status(named: name, in: directoryDescriptor)
        } catch let error as AtomicPOSIXError where error.code == ENOENT {
            return
        }
        guard identity(of: information) == expectedIdentity else {
            throw AtomicPOSIXError(code: ESTALE)
        }
        guard unlinkat(directoryDescriptor, name, 0) == 0 else {
            throw AtomicPOSIXError(code: errno)
        }
    }

    private func status(
        named name: String,
        in directoryDescriptor: Int32
    ) throws -> stat {
        var information = stat()
        guard
            fstatat(
                directoryDescriptor,
                name,
                &information,
                AT_SYMLINK_NOFOLLOW
            ) == 0
        else {
            throw AtomicPOSIXError(code: errno)
        }
        return information
    }

    private func requireIdentity(
        _ expectedIdentity: AtomicFileIdentity,
        named name: String,
        in directoryDescriptor: Int32
    ) throws {
        let information = try status(named: name, in: directoryDescriptor)
        guard identity(of: information) == expectedIdentity else {
            throw AtomicPOSIXError(code: ESTALE)
        }
    }

    private func identity(of information: stat) -> AtomicFileIdentity {
        AtomicFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino)
        )
    }

    private func readAll(
        from descriptor: Int32,
        maximumByteCount: Int
    ) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                guard errno == EINTR else {
                    throw AtomicPOSIXError(code: errno)
                }
                continue
            }
            guard count > 0 else {
                return result
            }
            guard result.count <= maximumByteCount - count else {
                throw AtomicPOSIXError(code: EFBIG)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
