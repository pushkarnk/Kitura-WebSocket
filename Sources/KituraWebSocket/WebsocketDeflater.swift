import NIO
import NIOWebSocket
import CZlib

class WebsocketDeflater : ChannelOutboundHandler {
    typealias OutboundIn = WebSocketFrame 
    typealias OutboundOut = WebSocketFrame 

    public init() { }

    private var stream: z_stream = z_stream()

    var payload: ByteBuffer?

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = unwrapOutboundIn(data)

        self.payload = frame.data
        let deflatedPayload = deflatePayload(allocator: ctx.channel.allocator)!

        let deflatedFrame = WebSocketFrame(fin: frame.fin, rsv1: true, opcode: frame.opcode, data: deflatedPayload)
        _ = ctx.writeAndFlush(self.wrapOutboundOut(deflatedFrame))
    }

    private func initializeEncoder() {
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        let rc = CZlib_deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY)
        precondition(rc == Z_OK, "Unexpected return from zlib init: \(rc)")
    }

    private func deinitializeEncoder() {
         deflateEnd(&stream)
    }

    func deflatePayload(allocator: ByteBufferAllocator) -> ByteBuffer? {
        initializeEncoder()
        defer {
            deinitializeEncoder()
        }
        return compressPayload(allocator: allocator, flag: Z_FINISH)
    }

    private func compressPayload(allocator: ByteBufferAllocator, flag: Int32) -> ByteBuffer? {
        guard var payload = self.payload, payload.readableBytes > 0 else {
            return nil
        }

        // deflateBound() provides an upper limit on the number of bytes the input can
        // compress to. We add 5 bytes to handle the fact that Z_SYNC_FLUSH will append
        // an empty stored block that is 5 bytes long.
        let bufferSize = Int(deflateBound(&stream, UInt(payload.readableBytes)))
        var outputBuffer = allocator.buffer(capacity: bufferSize)

        // Now do the one-shot compression. All the data should have been consumed.
        stream.oneShotDeflate(from: &payload, to: &outputBuffer, flag: flag)
        precondition(payload.readableBytes == 0)
        precondition(outputBuffer.readableBytes > 0)
        return outputBuffer
    }
}

private extension z_stream {
    /// Executes deflate from one buffer to another buffer. The advantage of this method is that it
    /// will ensure that the stream is "safe" after each call (that is, that the stream does not have
    /// pointers to byte buffers any longer).
    mutating func oneShotDeflate(from: inout ByteBuffer, to: inout ByteBuffer, flag: Int32) {
        defer {
            self.avail_in = 0
            self.next_in = nil
            self.avail_out = 0
            self.next_out = nil
        }

        from.readWithUnsafeMutableReadableBytes { dataPtr in
            let typedPtr = dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let typedDataPtr = UnsafeMutableBufferPointer(start: typedPtr,
                                                          count: dataPtr.count)

            self.avail_in = UInt32(typedDataPtr.count)
            self.next_in = typedDataPtr.baseAddress!

            let rc = deflateToBuffer(buffer: &to, flag: flag)
            precondition(rc == Z_OK || rc == Z_STREAM_END, "One-shot compression failed: \(rc)")

            return typedDataPtr.count - Int(self.avail_in)
        }
    }

    /// A private function that sets the deflate target buffer and then calls deflate.
    /// This relies on having the input set by the previous caller: it will use whatever input was
    /// configured.
    private mutating func deflateToBuffer(buffer: inout ByteBuffer, flag: Int32) -> Int32 {
        var rc = Z_OK

        buffer.writeWithUnsafeMutableBytes { outputPtr in
            let typedOutputPtr = UnsafeMutableBufferPointer(start: outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                            count: outputPtr.count)
            self.avail_out = UInt32(typedOutputPtr.count)
            self.next_out = typedOutputPtr.baseAddress!
            rc = deflate(&self, flag)
            return typedOutputPtr.count - Int(self.avail_out)
        }

        return rc
    }
}
