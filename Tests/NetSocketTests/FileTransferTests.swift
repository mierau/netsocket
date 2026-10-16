import Foundation
import NetSocket
import os
import Testing

@Suite("File transfers", .timeLimit(.minutes(1)))
struct FileTransferTests {
  // MARK: Sending

  @Test func writeFileFromURL() async throws {
    try await withTemporaryDirectory { directory in
      let payload = patternData(count: 1024 * 1024 + 123)
      let url = directory.appending(component: "upload.bin")
      try payload.write(to: url)

      try await withConnectedSocket { socket, peer in
        let received = Task { try await peer.receive(payload.count) }

        var last: NetSocket.FileProgress?
        for try await progress in await socket.writeFile(from: url, chunkSize: 64 * 1024) {
          last = progress
        }

        #expect(try await received.value == payload)
        #expect(last?.sent == payload.count)
        #expect(last?.total == payload.count)
        #expect(last?.progress == 1)
      }
    }
  }

  @Test func writeFileFromDirectoryThrows() async throws {
    try await withTemporaryDirectory { directory in
      try await withConnectedSocket { socket, _ in
        await expect(.invalidFile(directory)) {
          for try await _ in await socket.writeFile(from: directory) {}
        }
      }
    }
  }

  @Test func writeFileFromHandleThatEndsEarlyThrows() async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appending(component: "short.bin")
      try patternData(count: 10).write(to: url)
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }

      try await withConnectedSocket { socket, _ in
        await expect(.fileEndedEarly(expected: 20, got: 10)) {
          for try await _ in await socket.writeFile(from: handle, length: 20) {}
        }
      }
    }
  }

  @Test func writeEmptyFile() async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appending(component: "empty.bin")
      try Data().write(to: url)

      try await withConnectedSocket { socket, _ in
        var updates: [NetSocket.FileProgress] = []
        for try await progress in await socket.writeFile(from: url) {
          updates.append(progress)
        }
        #expect(updates.count == 1)
        #expect(updates.first?.progress == 1)
      }
    }
  }

  // MARK: Receiving

  @Test func receiveFileToURL() async throws {
    try await withTemporaryDirectory { directory in
      let payload = patternData(count: 1024 * 1024 + 321)
      let url = directory.appending(component: "download.bin")

      try await withConnectedSocket { socket, peer in
        let sending = Task { try await peer.send(payload + Data([0xEE])) }

        let lastSent = OSAllocatedUnfairLock(initialState: 0)
        let written = try await socket.receiveFile(to: url, length: payload.count, chunkSize: 64 * 1024) { progress in
          lastSent.withLock { $0 = progress.sent }
        }

        #expect(written == payload.count)
        #expect(lastSent.withLock { $0 } == payload.count)
        #expect(try Data(contentsOf: url) == payload)
        // Only the file's own bytes were consumed
        #expect(try await socket.read(UInt8.self) == 0xEE)
        try await sending.value
      }

      // The temporary .part file is gone
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["download.bin"])
    }
  }

  @Test(arguments: [true, false])
  func receiveFileReplacesExistingFile(atomic: Bool) async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appending(component: "existing.bin")
      try Data("a much longer old file".utf8).write(to: url)

      try await withConnectedSocket { socket, peer in
        try await peer.send(Data("new".utf8))
        try await socket.receiveFile(to: url, length: 3, atomic: atomic)
      }

      #expect(try Data(contentsOf: url) == Data("new".utf8))
    }
  }

  @Test(arguments: [true, false])
  func receiveFileWithoutOverwriteFailsBeforeReading(atomic: Bool) async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appending(component: "keep.bin")
      try Data("old".utf8).write(to: url)

      try await withConnectedSocket { socket, peer in
        try await peer.send(Data("new".utf8))
        do {
          try await socket.receiveFile(to: url, length: 3, overwrite: false, atomic: atomic)
          Issue.record("Expected receiveFile to throw")
        } catch let error as CocoaError {
          #expect(error.code == .fileWriteFileExists)
        }
        // The socket's data is untouched
        #expect(try await socket.read(3, encoding: .utf8) == "new")
      }

      #expect(try Data(contentsOf: url) == Data("old".utf8))
      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) == ["keep.bin"])
    }
  }

  @Test func failedReceiveRemovesPartialFile() async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appending(component: "partial.bin")

      try await withConnectedSocket { socket, peer in
        try await peer.send(patternData(count: 10))
        await peer.close()
        await expect(.insufficientData(expected: 100, got: 10)) {
          try await socket.receiveFile(to: url, length: 100)
        }
      }

      #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).isEmpty)
    }
  }

  @Test func receiveEmptyFile() async throws {
    try await withTemporaryDirectory { directory in
      let url = directory.appending(component: "empty.bin")
      try await withConnectedSocket { socket, _ throws in
        #expect(try await socket.receiveFile(to: url, length: 0) == 0)
      }
      #expect(try Data(contentsOf: url).isEmpty)
    }
  }

  @Test func receiveFileToHandle() async throws {
    try await withTemporaryDirectory { directory in
      let payload = patternData(count: 700_000)
      let url = directory.appending(component: "stream.bin")
      FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
      let handle = try FileHandle(forWritingTo: url)

      try await withConnectedSocket { socket, peer in
        let sending = Task { try await peer.send(payload) }

        var last: NetSocket.FileProgress?
        for try await progress in await socket.receiveFile(to: handle, length: payload.count, chunkSize: 32 * 1024) {
          last = progress
        }
        try handle.close()

        #expect(last?.sent == payload.count)
        #expect(last?.progress == 1)
        #expect(try Data(contentsOf: url) == payload)
        try await sending.value
      }
    }
  }
}
