# NetSocket

Async/await TCP sockets for Swift, built on Network.framework.

NetSocket wraps `NWConnection` in an actor with a receive buffer, so you can parse binary and line-based protocols one field at a time with plain `try await` calls. Each read waits until enough bytes have arrived, however the network split them into packets.

It was built for [Hotline](https://github.com/mierau/hotline), a client for the classic Hotline protocol, and is used there for chat, trackers, and file transfers.

```swift
import NetSocket

let socket = try await NetSocket.connect(host: "example.com", port: 80)
try await socket.write("GET / HTTP/1.0\r\nHost: example.com\r\n\r\n")

let status = try await socket.read(until: .carriageReturnLineFeed)
print(status) // HTTP/1.0 200 OK
```

## Features

- **Field-by-field reads.** Read exactly *n* bytes, a big- or little-endian integer, a `Float`, `Double` or `Bool`, a fixed-length string in any `String.Encoding`, or everything up to a delimiter.
- **Messages that encode and decode themselves.** Conform to `NetSocketEncodable` and `NetSocketDecodable` and send or receive a whole message in one call.
- **Packet helpers.** Append integers, floats, bools and strings to `Data` or `[UInt8]` in either byte order, and read them back at an offset.
- **File transfers.** Stream files between disk and socket in chunks, with progress, transfer speed, and time remaining. Downloads can be written atomically.
- **Backpressure.** Receiving pauses while too much unread data is buffered, so TCP flow control slows a fast sender down instead of the buffer growing without limit.
- **Clean shutdown.** Bytes the peer sent before closing can still be read. Pending reads fail with a clear error when the connection closes, and cancelling a read leaves the socket usable.
- **TLS and keepalive.** Turn on TLS with one argument, and TCP keepalive with one setting.
- **Swift 6 ready.** `NetSocket` is an actor, and the package builds in the Swift 6 language mode with strict concurrency checking.

## Requirements

- Swift 6.0+ (Xcode 16+)
- macOS 13+, iOS 16+, tvOS 16+, or visionOS 1+

## Installation

Add NetSocket to your `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/mierau/netsocket.git", from: "0.1.0"),
],
targets: [
  .target(name: "MyApp", dependencies: [
    .product(name: "NetSocket", package: "netsocket"),
  ]),
]
```

In Xcode, choose **File › Add Package Dependencies…** and enter `https://github.com/mierau/netsocket.git`.

## Usage

### Connecting

```swift
// Plain TCP
let socket = try await NetSocket.connect(host: "hotline.example.com", port: 5500)

// TLS
let secure = try await NetSocket.connect(host: "example.com", port: 443, tls: .enabled())

// Keepalive and buffer limits
var config = NetSocket.Config()
config.enableKeepAlive = true
config.keepAliveIdleTime = 60
let chat = try await NetSocket.connect(host: "hotline.example.com", port: 5500, config: config)
```

`connect` returns once the connection is ready. It throws `NetSocketError.failed` if the connection is refused or fails. To give up after a while, cancel the task; connect then throws `CancellationError`.

For full control over the connection, pass an `NWEndpoint.Host`, an `NWEndpoint.Port`, and your own `NWParameters`:

```swift
let parameters = NWParameters.tcp
parameters.requiredInterfaceType = .wiredEthernet
let socket = try await NetSocket.connect(host: .ipv4(.loopback), port: 5500, parameters: parameters)
```

### Writing

```swift
try await socket.write(Data([0x01, 0x02]))            // Raw bytes
try await socket.write(UInt32(0xC0FFEE))              // Big-endian (network byte order) by default
try await socket.write(UInt16(42), endian: .little)
try await socket.write(true)                          // One byte, 1 or 0
try await socket.write(Float(1.5))                    // IEEE 754 bit pattern
try await socket.write("hello")                       // UTF-8 by default
try await socket.write("Café", encoding: .macOSRoman)
```

Each write returns once the network stack has taken the bytes, and reports how many it sent.

### Reading

```swift
let header = try await socket.read(16)                         // Exactly 16 bytes
let type = try await socket.read(UInt16.self)                  // Big-endian by default
let size = try await socket.read(UInt32.self, endian: .little)
let flag = try await socket.read(Bool.self)
let name = try await socket.read(Int(size), encoding: .utf8)   // Fixed-length string

let line = try await socket.read(until: .lineFeed)                       // A line, without the "\n"
let record = try await socket.read(until: .zeroByte, maxBytes: 1024)     // Give up after 1 KB
let chunk = try await socket.read(past: Data("--boundary".utf8))         // Raw bytes before a marker

let some = try await socket.read(upTo: 4096)   // Whatever's buffered, up to 4 KB, once anything arrives
```

### Peeking and skipping

```swift
if let magic = await socket.peek(4) {       // Already buffered? Doesn't wait or consume
  print(magic)
}
let next = try await socket.peek(awaiting: 4)   // Waits for 4 bytes, but leaves them unread
try await socket.skip(128)                      // Discard bytes, even more than the buffer holds
try await socket.skip(past: Delimiter.carriageReturnLineFeed.data)
```

### Messages

Types that know how to encode or decode themselves can be sent and received in one call. Decoding reads fields straight from the socket, so a message doesn't need to know its own size up front:

```swift
struct Greeting {
  let id: UInt32
  let name: String
}

extension Greeting: NetSocketEncodable {
  func encode(endian: Endian) throws -> Data {
    let name = Data(self.name.utf8)
    var data = Data()
    data.append(id, endian: endian)
    data.append(UInt16(name.count), endian: endian)
    data.append(name)
    return data
  }
}

extension Greeting: NetSocketDecodable {
  init(from socket: NetSocket, endian: Endian) async throws {
    self.id = try await socket.read(UInt32.self, endian: endian)
    let length = try await socket.read(UInt16.self, endian: endian)
    self.name = try await socket.read(Int(length), encoding: .utf8)
  }
}

try await socket.send(Greeting(id: 1, name: "Hotline"))
let reply = try await socket.receive(Greeting.self)
```

Declaring `init(from:endian:)` in an extension keeps the struct's memberwise initializer. If decoding throws partway through a message, the bytes it read are gone, so the connection is usually best closed.

### Packets in memory

The same kinds of reads and writes work on bytes you already have: `Data`, `[UInt8]`, or slices of either. Append values to build a packet to send in one write, or read them at an offset to parse one you've received:

```swift
var packet = Data()
packet.append(UInt16(107), endian: .big)
packet.append(UInt32(0), endian: .big)
packet.append(true)
try packet.append("guest", encoding: .macOSRoman)

let type = packet.read(UInt16.self, at: 0)               // 107
let flag = packet.read(Bool.self, at: 6)                 // true
let name = packet.read(5, at: 7, encoding: .macOSRoman)  // "guest"
let missing = packet.read(UInt32.self, at: 10)           // nil: past the end
```

Reads return nil when there aren't enough bytes, rather than throwing. Offsets count from the start of the collection, so they work the same on slices.

Unlike the socket's writes, the numeric appends have no default byte order, so you always pass `endian:`. With a default, `data.append(0)` would append an 8-byte `Int` instead of a single byte.

### File transfers

Uploads stream from disk in chunks. The stream reports progress, transfer speed, and time remaining:

```swift
for try await progress in await socket.writeFile(from: fileURL) {
  print("\(Int(progress.progress * 100))%", progress.formattedSpeed ?? "")
}
```

Downloads need the length from your protocol. By default they're written to a temporary file and moved into place when complete, so a failed transfer never leaves a partial file behind:

```swift
let length = Int(try await socket.read(UInt32.self))
try await socket.receiveFile(to: destinationURL, length: length) { progress in
  print("\(progress.sent) of \(length) bytes")
}
```

To send or receive part of a larger stream, such as one fork of a classic Mac file, use the `FileHandle` versions, `writeFile(from:length:)` and `receiveFile(to:length:)`. Cancel the task that's consuming the stream to stop a transfer.

`TransferRateEstimator` is public too, if you want the same speed and time-remaining estimates for transfers you drive yourself.

### Closing and errors

```swift
await socket.close()        // Waits for unsent data to go out
await socket.forceClose()   // Doesn't
```

Closing fails any pending reads and writes with `NetSocketError.closed`. When the peer closes the connection, anything it sent before closing can still be read. Reads after that throw:

- `NetSocketError.closed` if everything was read
- `NetSocketError.insufficientData(expected:got:)` if the connection closed partway through a read

```swift
do {
  while true {
    let line = try await socket.read(until: .lineFeed)
    print(line)
  }
} catch NetSocketError.closed {
  print("Server hung up")
}
```

Cancelling a task that's waiting on a read throws `CancellationError`, and the socket stays usable.

### Buffering

The socket buffers data as it arrives, up to `Config.receiveHighWaterMark` unread bytes (1 MB by default). Above that it stops receiving until reads drain the buffer, which lets TCP flow control slow the sender. A single read larger than the high-water mark still works; receiving resumes as soon as a read needs more than is buffered.

As a final safeguard, the connection is closed with `NetSocketError.framingExceeded` if more than `Config.maxBufferBytes` (8 MB by default) would be buffered. That only happens for a single read larger than the limit, or a delimiter that never arrives. Use `maxBytes` on delimited reads to catch the second case sooner, without closing the connection.

## Documentation

The API is documented with DocC. In Xcode, choose **Product › Build Documentation**.

## Testing

```bash
swift test
```

The tests connect to a real TCP server on the loopback interface, so they exercise actual packet boundaries, peer closes, and flow control, not mocks.

## License

NetSocket is available under the MIT License. See [LICENSE](LICENSE).
