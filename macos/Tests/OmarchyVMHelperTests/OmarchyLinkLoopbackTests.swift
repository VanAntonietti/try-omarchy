import Darwin
import Foundation
import Testing
@testable import OmarchyVMHelper

@Suite("Omarchy Link cross-language loopback")
struct OmarchyLinkLoopbackTests {
    @Test("a real Rust guest exchanges framed Queries, cancellation, and Invalidation with the Swift fake host")
    func exchangesWithRustGuest() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["cargo", "run", "--locked", "--offline", "--quiet", "--example", "fake-peer"]
        process.currentDirectoryURL = repository.appendingPathComponent("guest/omarchy-link")
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var host = OmarchyLinkFakeHost(serviceModes: .init(calendar: .read, messages: .off, notes: .off))
        let hello = try readFrame(output.fileHandleForReading, deadline: deadline)
        try input.fileHandleForWriting.write(contentsOf: host.receive(hello))

        // Concurrent Calendar-list and agenda Queries, then cancellation.
        var replies = Data()
        for _ in 0..<4 {
            let frame = try readFrame(output.fileHandleForReading, deadline: deadline)
            #expect(try host.receive(frame.prefix(2)).isEmpty)
            replies.append(try host.receive(frame.dropFirst(2)))
        }
        #expect(try host.complete("q3").isEmpty)
        replies.append(try host.invalidate(.calendar))
        replies.append(try host.complete("q2"))
        replies.append(try host.complete("q1"))
        // Also split a host frame inside its header across pipe writes.
        try input.fileHandleForWriting.write(contentsOf: replies.prefix(1))
        try input.fileHandleForWriting.write(contentsOf: replies.dropFirst())
        try input.fileHandleForWriting.close()
        #expect(try readBytes(1, from: output.fileHandleForReading, deadline: deadline).isEmpty)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        try #require(exited.wait(timeout: .now() + max(0, seconds)) == .success,
                     "Rust loopback did not exit before its deadline")
        #expect(process.terminationStatus == 0)
        try host.finish()
    }

    private func readFrame(_ handle: FileHandle, deadline: ContinuousClock.Instant) throws -> Data {
        let header = try readBytes(4, from: handle, deadline: deadline)
        try #require(header.count == 4)
        let size = header.reduce(0) { ($0 << 8) | Int($1) }
        let boundedSize = try #require((1...65536).contains(size) ? size : nil)
        let payload = try readBytes(boundedSize, from: handle, deadline: deadline)
        try #require(payload.count == boundedSize)
        return header + payload
    }

    private func readBytes(_ count: Int, from handle: FileHandle, deadline: ContinuousClock.Instant) throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = ContinuousClock.now.duration(to: deadline)
            try #require(remaining > .zero, "Rust loopback exceeded its 30-second deadline")
            let milliseconds = remaining.components.seconds * 1000 + remaining.components.attoseconds / 1_000_000_000_000_000
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(clamping: max(1, milliseconds)))
            if ready < 0 && errno == EINTR { continue }
            try #require(ready > 0, "Rust loopback did not produce bytes before its deadline")
            var buffer = [UInt8](repeating: 0, count: count - result.count)
            let readCount = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if readCount < 0 && errno == EINTR { continue }
            try #require(readCount >= 0)
            if readCount == 0 { break }
            result.append(contentsOf: buffer.prefix(readCount))
        }
        return result
    }
}
