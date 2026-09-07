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

    /// The host-owned extended attribute the storage transaction writes on a
    /// new Workspace directory. Its record is `v1:<uuid>:<binding>`.
    static let linkWorkspaceIdentityAttribute = "dev.tryomarchy.workspace-identity"

    /// Read-only preflight of the Link Workspace identity for launcher UI.
    /// Missing, malformed, or substituted records yield nil, which disables
    /// only Link. The shell repeats this validation under its workspace lock
    /// before any launch, so this never authorizes access by itself.
    static func linkWorkspaceIdentity(directory: String) -> OmarchyLinkWorkspaceIdentity? {
        let length = getxattr(directory, linkWorkspaceIdentityAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0, length <= 512 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        guard getxattr(
            directory,
            linkWorkspaceIdentityAttribute,
            &buffer,
            buffer.count,
            0,
            XATTR_NOFOLLOW
        ) == length,
            let record = String(bytes: buffer, encoding: .utf8) else { return nil }
        let components = record.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0] == "v1",
              let identity = OmarchyLinkWorkspaceIdentity(rawValue: String(components[1])),
              let binding = try? binding(directory: directory),
              record == "v1:\(identity.rawValue):\(binding)" else { return nil }
        return identity
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
