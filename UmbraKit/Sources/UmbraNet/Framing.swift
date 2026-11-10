import Foundation
import NIOCore
import NIOPosix
import UmbraCore

@_exported import NIOCore
@_exported import NIOPosix

/// Splits the TCP byte stream into length-prefixed frames (see `Framing`).
///
/// Deliberately not NIO's `ByteToMessageHandler`: its handler conformances are conditional on a
/// `~Copyable` generic parameter, which the Swift runtime before iOS 18 cannot cast, so adding it to
/// a pipeline traps on iOS 16 and 17.
final class FrameDecoder: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    /// Bytes of an incomplete frame carried over from earlier reads.
    private var pending: ByteBuffer?
    private var failed = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        var buffer = unwrapInboundIn(data)
        if var earlier = pending {
            pending = nil  // sole owner, so appending doesn't copy
            earlier.writeBuffer(&buffer)
            buffer = earlier
        }
        do {
            while let frame = try Self.nextFrame(&buffer) {
                context.fireChannelRead(wrapInboundOut(frame))
            }
        } catch {
            failed = true
            context.fireErrorCaught(error)
            context.close(promise: nil)
            return
        }
        if buffer.readableBytes > 0 {
            buffer.discardReadBytes()
            pending = buffer
        }
    }

    static func nextFrame(_ buffer: inout ByteBuffer) throws -> ByteBuffer? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return nil }
        guard length <= Framing.maxFrame else { throw UmbraError.frameTooLarge }
        guard buffer.readableBytes >= 4 + Int(length) else { return nil }
        buffer.moveReaderIndex(forwardBy: 4)
        return buffer.readSlice(length: Int(length))
    }
}

public typealias FrameChannel = NIOAsyncChannel<ByteBuffer, ByteBuffer>

extension Channel {
    /// Installs framing (and optionally an idle timeout) and wraps the channel for async use.
    /// Call from the channel initializer.
    public func makeFrameChannel(idleTimeout: TimeAmount? = nil) -> EventLoopFuture<FrameChannel> {
        eventLoop.makeCompletedFuture {
            if let idleTimeout {
                try pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: idleTimeout))
                try pipeline.syncOperations.addHandler(CloseOnIdle())
            }
            try pipeline.syncOperations.addHandler(FrameDecoder())
            return try FrameChannel(wrappingChannelSynchronously: self)
        }
    }
}

/// Closes connections that sent nothing within the idle window, so dead peers don't pin resources.
final class CloseOnIdle: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}

/// Lets a single async iterator be handed between sequential phases (handshake, then reader task).
/// Access is strictly sequential, never concurrent.
public final class UncheckedBox<T>: @unchecked Sendable {
    public var value: T
    public init(_ value: T) { self.value = value }
}

extension ByteBuffer {
    public var data: Data { Data(readableBytesView) }
    public static func frame(_ payload: Data) -> ByteBuffer { ByteBuffer(bytes: Framing.encode(payload)) }
}

/// Runs `operation`, failing with `UmbraError.handshakeFailed` if it takes longer than `seconds`.
public func withDeadline<T: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw UmbraError.handshakeFailed
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
