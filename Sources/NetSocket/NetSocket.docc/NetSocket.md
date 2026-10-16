# ``NetSocket``

Async/await TCP sockets for binary and line-based protocols, built on Network.framework.

## Overview

NetSocket wraps `NWConnection` in an actor with a receive buffer, so a protocol can be parsed one field at a time. Each read waits until enough bytes have arrived, however the network happened to split them into packets:

```swift
import NetSocket

let socket = try await NetSocket.connect(host: "hotline.example.com", port: 5500)

// Send a handshake
try await socket.write(Data("TRTPHOTL".utf8))
try await socket.write(UInt16(1))
try await socket.write(UInt16(2))

// Read the reply, field by field
let magic = try await socket.read(4, encoding: .ascii)
let error = try await socket.read(UInt32.self)
```

Integers can be read and written in either byte order, strings in any `String.Encoding`, and records can be split on a ``Delimiter`` such as a line ending. Larger structures can conform to ``NetSocketEncodable`` and ``NetSocketDecodable`` to encode and decode themselves.

The same kinds of reads and writes work on bytes in memory. `Data`, `[UInt8]` and their slices get `append(_:endian:)` and `read(_:at:endian:)` methods, for building a packet before sending it or parsing one already received.

Files go straight between disk and socket in chunks, with a progress stream that includes transfer speed and time remaining.

### Flow control

The socket stops receiving once ``NetSocket/NetSocket/Config-swift.struct/receiveHighWaterMark`` unread bytes are buffered, and starts again as reads drain the buffer. While it's paused, TCP flow control slows the sender, so a slow reader never buffers a fast sender's whole stream. As a final safeguard, the connection is closed with ``NetSocketError/framingExceeded(max:)`` if more than ``NetSocket/NetSocket/Config-swift.struct/maxBufferBytes`` would be buffered.

### Closing

When the peer closes the connection, anything it sent first can still be read. Reads after that throw ``NetSocketError/closed``, or ``NetSocketError/insufficientData(expected:got:)`` if the connection closed partway through a read. Calling ``NetSocket/NetSocket/close()`` fails pending reads and writes and discards unread data.

Cancelling the task that's waiting on a read throws `CancellationError` and leaves the socket usable.

## Topics

### Essentials

- ``NetSocket/NetSocket``
- ``TLSPolicy``

### Byte Order and Framing

- ``Endian``
- ``Delimiter``

### Messages

- ``NetSocketEncodable``
- ``NetSocketDecodable``

### File Transfers

- ``NetSocket/NetSocket/FileProgress``
- ``TransferRateEstimator``

### Errors

- ``NetSocketError``
