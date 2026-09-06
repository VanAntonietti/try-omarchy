import Darwin
import Foundation

/// Local launcher operations, never exposed as Omarchy Link Capabilities.
enum WorkspaceStorage {
    static func synchronize(path: String) throws {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw HelperError.io("Cannot open storage durability target") }
        defer { close(descriptor) }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_uid == getuid(),
              [S_IFREG, S_IFDIR].contains(information.st_mode & S_IFMT) else {
            throw HelperError.io("Storage durability target must be an owned file or directory")
        }
        // fsync moves dirty data/attributes to the device. F_FULLFSYNC then
        // orders the device's own write cache before publication can proceed.
        guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw HelperError.io("Storage durability barrier failed")
        }
    }

    static func binding(directory: String) throws -> String {
        let directoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        let volume = try directoryURL.resourceValues(forKeys: [.volumeUUIDStringKey])
        guard let volumeUUID = volume.volumeUUIDString.flatMap(UUID.init(uuidString:)) else {
            throw HelperError.io("Workspace volume has no persistent UUID")
        }
        var directoryInfo = stat()
        var diskInfo = stat()
        guard lstat(directory, &directoryInfo) == 0,
              lstat(directoryURL.appendingPathComponent("rootfs.ext4").path, &diskInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              diskInfo.st_mode & S_IFMT == S_IFREG,
              directoryInfo.st_uid == getuid(), diskInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o777 == 0o700,
              diskInfo.st_mode & 0o777 == 0o600,
              directoryInfo.st_dev == diskInfo.st_dev else {
            throw HelperError.io("Workspace binding requires a private owned directory and disk")
        }
        // st_dev is only useful for the same-volume check above, not persistent
        // state: device enumeration can change after reboot or drive remount.
        return "\(volumeUUID.uuidString.lowercased()):\(directoryInfo.st_ino):\(diskInfo.st_ino)"
    }
}
