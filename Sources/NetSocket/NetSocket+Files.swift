// NetSocket: Files
// Dustin Mierau • @mierau
// MIT License

import Foundation

public extension NetSocket {
  /// Send a file's contents, reporting progress as it goes
  ///
  /// Opens and closes the file itself. The progress stream works the same as in
  /// ``writeFile(from:length:chunkSize:)``.
  ///
  /// ```swift
  /// for try await progress in await socket.writeFile(from: url) {
  ///   print("\(progress.sent) of \(progress.total ?? 0)", progress.formattedSpeed ?? "")
  /// }
  /// ```
  ///
  /// The stream throws ``NetSocketError/invalidFile(_:)`` if `url` isn't a regular file.
  func writeFile(from url: URL, chunkSize: Int = 256 * 1024) -> AsyncThrowingStream<FileProgress, Error> {
    // This stream wrapper manages the FileHandle's lifetime.
    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      // Capture self (the actor) to use in detached task
      let actor = self

      // Open file on a background thread (file I/O is blocking)
      let task = Task.detached {
        let fh: FileHandle
        let total: Int

        // 1. Open file and get length (blocking I/O, done off-actor)
        do {
          total = try NetSocket.fileLength(at: url)
          fh = try FileHandle(forReadingFrom: url)
        } catch {
          continuation.finish(throwing: error)
          return
        }

        // 2. Now switch to the actor context to call the actor-isolated method
        let stream = await actor.writeFile(
          from: fh,
          length: total,
          chunkSize: chunkSize
        )

        // 3. Forward all elements from the underlying stream to our stream
        do {
          for try await progress in stream {
            try Task.checkCancellation() // Exit early if cancelled
            continuation.yield(progress)
          }
          try? fh.close()
          continuation.finish()
        } catch is CancellationError {
          try? fh.close()
          continuation.finish()
        } catch {
          try? fh.close()
          continuation.finish(throwing: error)
        }
      }

      // If the *consumer* cancels the stream, we cancel our managing task.
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  /// Send `length` bytes from an open file, reporting progress as it goes
  ///
  /// The transfer starts when the stream is created, not when it's iterated. Each value carries
  /// the running total. A consumer that falls behind gets the latest value, and always the last
  /// one. Cancel the consuming task to stop the transfer. The caller opens and closes `fileHandle`.
  ///
  /// The stream throws ``NetSocketError/fileEndedEarly(expected:got:)`` if the file is shorter
  /// than `length`.
  func writeFile(from fileHandle: FileHandle, length: Int, chunkSize: Int = 256 * 1024) -> AsyncThrowingStream<FileProgress, Error> {
    precondition(length >= 0, "length must be >= 0")

    if length == 0 {
      return AsyncThrowingStream { continuation in
        continuation.yield(.init(sent: 0, total: 0, bytesPerSecond: 0, estimatedTimeRemaining: 0))
        continuation.finish()
      }
    }

    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish()
          return
        }

        var estimator = TransferRateEstimator(total: length)

        do {
          try await self.ensureReady()

          while estimator.transferred < length {
            try Task.checkCancellation()

            let toRead = min(chunkSize, length - estimator.transferred)

            // Read from disk
            guard let chunk = try fileHandle.read(upToCount: toRead), !chunk.isEmpty else {
              throw NetSocketError.fileEndedEarly(expected: length, got: estimator.transferred)
            }

            // Write to network
            try await self.write(chunk)

            // Update estimator and yield progress
            let progress = estimator.update(bytes: chunk.count)
            continuation.yield(progress)
          }

          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  /// Receive `length` bytes into an open file, reporting progress as it goes
  ///
  /// The progress stream and cancellation work the same as in ``writeFile(from:length:chunkSize:)``.
  /// The caller opens and closes `fileHandle`.
  func receiveFile(to fileHandle: FileHandle, length: Int, chunkSize: Int = 256 * 1024) -> AsyncThrowingStream<FileProgress, Error> {
    precondition(length >= 0, "length must be >= 0")

    if length == 0 {
      return AsyncThrowingStream { continuation in
        continuation.yield(.init(sent: 0, total: 0, bytesPerSecond: 0, estimatedTimeRemaining: 0))
        continuation.finish()
      }
    }

    return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish()
          return
        }

        var estimator = TransferRateEstimator(total: length)

        do {
          var remaining: Int = length

          while remaining > 0 {
            try Task.checkCancellation()
            let n = min(chunkSize, remaining)

            let chunk = try await self.read(n)
            try fileHandle.write(contentsOf: chunk)

            remaining -= chunk.count
            let progress = estimator.update(bytes: chunk.count)
            continuation.yield(progress)
          }

          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  /// Receive `length` bytes into a file at `url`, without holding the whole file in memory
  ///
  /// `length` has to come from the protocol; nothing is read from the socket to find it. With
  /// `atomic`, data goes to a temporary `.part` file next to `url`, which is renamed into place
  /// when complete and deleted if the transfer fails.
  ///
  /// - Parameters:
  ///   - url: Where to save the file
  ///   - length: How many bytes to read from the socket
  ///   - chunkSize: Most bytes to read and write at a time
  ///   - overwrite: Replace an existing file at `url`. When false and a file is already there,
  ///     this throws `CocoaError.fileWriteFileExists` before reading anything from the socket.
  ///   - atomic: Write to a temporary file and move it into place when complete
  ///   - progress: Called after each chunk is written
  /// - Returns: The number of bytes written, which is `length` on success
  @discardableResult
  func receiveFile(
    to url: URL,
    length: Int,
    chunkSize: Int = 256 * 1024,
    overwrite: Bool = true,
    atomic: Bool = true,
    progress: (@Sendable (FileProgress) -> Void)? = nil
  ) async throws -> Int {
    precondition(length >= 0, "length must be >= 0")

    let fm = FileManager.default

    // Check before reading anything, so the stream stays in sync when this throws.
    if !overwrite, fm.fileExists(atPath: url.path(percentEncoded: false)) {
      throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: url])
    }

    // Prepare destination (optionally atomic)
    let destination = atomic
      ? url.deletingLastPathComponent().appending(component: ".\(url.lastPathComponent).part-\(UUID().uuidString)")
      : url
    guard fm.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
    }

    var estimator = TransferRateEstimator(total: length)

    do {
      let fh = try FileHandle(forWritingTo: destination)
      do {
        while estimator.transferred < length {
          try Task.checkCancellation()
          let chunk = try await self.read(min(chunkSize, length - estimator.transferred))
          try fh.write(contentsOf: chunk)
          // Update outside the optional call, which would skip it when there's no handler.
          let update = estimator.update(bytes: chunk.count)
          progress?(update)
        }
        try fh.close()
      } catch {
        try? fh.close()
        throw error
      }

      // Move into place
      if atomic {
        if overwrite { try? fm.removeItem(at: url) }
        try fm.moveItem(at: destination, to: url)
      }
    } catch {
      // Clean up the partial file if we were writing atomically
      if atomic { try? fm.removeItem(at: destination) }
      throw error
    }

    return estimator.transferred
  }

  private static func fileLength(at url: URL) throws -> Int {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile == true else {
      throw NetSocketError.invalidFile(url)
    }
    if let size = values.fileSize {
      return size
    }
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    if let size = attrs[.size] as? NSNumber {
      return size.intValue
    }
    throw NetSocketError.invalidFile(url)
  }
}
