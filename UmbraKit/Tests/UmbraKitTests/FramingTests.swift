import Foundation
import NIOEmbedded
import Testing
import UmbraCore
@testable import UmbraNet

@Suite struct FramingTests {
    /// The cast NIO performs in `addHandler`; it failed for `ByteToMessageHandler` on iOS 16 and 17.
    @Test func decoderIsAnInboundHandler() {
        let handler: ChannelHandler = FrameDecoder()
        #expect(handler is _ChannelInboundHandler)
    }

    @Test func framesSurviveSplitAndCoalescedReads() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(FrameDecoder())
        let payloads = [Data("one".utf8), Data(), Data(repeating: 7, count: 70_000), Data("last".utf8)]
        let stream = payloads.map(Framing.encode).reduce(Data(), +)

        // Odd chunk sizes split length prefixes and bodies, and merge several frames into one read.
        let sizes = [1, 2, 3, 5, 9, 4_000, 70_000, 64]
        var offset = 0
        var step = 0
        while offset < stream.count {
            let end = min(offset + sizes[step % sizes.count], stream.count)
            try channel.writeInbound(ByteBuffer(bytes: stream[offset..<end]))
            offset = end
            step += 1
        }

        var received: [Data] = []
        while let frame = try channel.readInbound(as: ByteBuffer.self) { received.append(frame.data) }
        #expect(received == payloads)
        _ = try channel.finish()
    }

    @Test func oversizedFrameClosesTheConnection() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(FrameDecoder())
        var header = ByteBuffer()
        header.writeInteger(UInt32(Framing.maxFrame + 1))
        #expect(throws: UmbraError.frameTooLarge) { try channel.writeInbound(header) }
        #expect(!channel.isActive)
    }
}
