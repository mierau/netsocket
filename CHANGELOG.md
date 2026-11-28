# Changelog

## 0.3.0

- Added `send(_:sent:)`, which queues bytes and returns straight away, rather than waiting for the network stack to take them as `write` does. They go in the order they're sent, after anything already written, and `sent` is told once they've gone, or why not. A server sending to many connections at once no longer waits on each one. In Hotline's server with 1,000 people on, a login took 18 ms of CPU instead of about 200, and a chat message 45 µs for each person it reached instead of about 130.
- `close()` sends what's queued before the connection ends, as it said it waited for unsent data: it ends the stream after it, and cancels once that's gone. Cancelling at once could drop bytes Network hadn't sent yet. `forceClose()` cuts short a `close()` that's still waiting on a peer that's stopped reading.
- Added `Config.noDelay`, which sends each write at once, rather than holding small ones back to gather them with what comes next, as Nagle's algorithm does.
- A socket lets go of its receive buffer once everything in it has been read, so a burst doesn't keep its memory for as long as the connection's open.
- README: covers `send`, `noDelay`, and how `close()` and `forceClose()` work together. It's clear that `close()` returns straight away while what's queued goes in the background, with an example of following up with `forceClose()` after a deadline.

## 0.2.0

- Added `NetSocket.listen(port:)`, which takes connections on a port. The `NetSocket.Listener` it returns hands each one over as a ready `NetSocket`, in a `for await` loop.
  - It listens over TLS with the new `TLSPolicy.server(identity:)`, and can be limited to one kind of interface, such as loopback. `server(identity:)` throws the new `NetSocketError.invalidIdentity` if the identity is missing its certificate or private key, so a bad identity fails before listening rather than in every client's handshake.
  - It advertises with Bonjour, and `advertise(_:)` changes or withdraws the advertisement while listening.
  - An `accepting` closure turns connections away by address before any TLS work, and connections that aren't ready within `readyTimeout` are closed.
  - `stop()` returns once the port is free, and the port can be listened on again straight away.
- Added `remoteEndpoint`, the host and port a socket is connected to, or for an accepted connection, where it came from.
- Added `Config.priority`, which a socket's work runs at, from its connection's events to its TLS, and the tasks it starts for itself. It's nil by default, which leaves things as they were. A server inside an app can choose `.utility`, so the work its connections make gives way to the app's own.
- README:
  - A new Listening section covers `listen` and its options, including where a TLS identity comes from and when `invalidIdentity` is thrown.
  - A new "Building a simple server" walkthrough puts it together, from taking connections to shutting the server down cleanly.
  - It notes that a peer's half-close counts as closing.
  - The opening example now shows the `HTTP/1.1 200 OK` that example.com actually sends.

## 0.1.0

First release as a standalone package, extracted from [Hotline](https://github.com/mierau/hotline) (`Hotline/Library/NetSocket` as of [59bc09e](https://github.com/mierau/hotline/commit/59bc09e)).

Changes from the version in Hotline:

- `writeFile(from:)`, `writeFile(from:length:chunkSize:)`, `receiveFile(to:length:chunkSize:)` and `receiveFile(to:length:chunkSize:overwrite:atomic:progress:)` are now public.
- `connect(host:port:)` takes a `tls:` argument, so `TLSPolicy` can be used.
- `connect(host:port:config:parameters:)` applies keepalive settings to a copy of `parameters` instead of changing the caller's.
- Added `read(Bool.self)`, `read(Float.self, endian:)` and `read(Double.self, endian:)` to match the existing writes.
- `read(until:)` takes an `encoding:` argument, which defaults to UTF-8.
- Renamed `peek(upto:)` to `peek(upTo:)`, to match `read(upTo:)`.
- `Delimiter.data` is public.
- Added the generic packet helpers from Hotline's `HotlineExtensions.swift`, for `Data`, `[UInt8]` and their slices. `append(_:endian:)` appends an integer, `Float` or `Double` in either byte order, `append(_:)` appends a `Bool`, and `append(_:encoding:)` appends a string. `read(_:at:endian:)` reads the same types back at an offset, and `read(_:at:)` and `read(_:at:encoding:)` read bytes and strings. Reads return nil past the end, and offsets count from the start of a slice.
- `NetSocketError` conforms to `LocalizedError`, so `localizedDescription` gives its description.
- `Endian`, `Delimiter` and `TransferRateEstimator` are `Sendable`, and `Endian` and `Delimiter` are `Hashable`.
- Fixed: with `overwrite: false`, `receiveFile(to:length:...)` replaced an existing file when `atomic` was false, and received the whole file before failing when `atomic` was true. It now throws `CocoaError.fileWriteFileExists` before reading anything from the socket.
- Fixed: `receiveFile(to:length:...)` left its temporary `.part` file behind if moving it into place failed.
- Fixed: data still arriving when `close()` was called could be buffered and read afterward.
- `receiveFile(to:length:...)` reports transfer speed and time remaining to its progress handler.
