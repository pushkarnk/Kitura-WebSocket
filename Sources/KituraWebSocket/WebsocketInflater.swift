import NIO
import CZlib
import NIOWebSocket

class WebsocketInflater : ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame 
    typealias InboundOut = WebSocketFrame

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) { }

    private var stream: z_stream = z_stream()

    var payload: ByteBuffer?

    public func write(ctx: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = unwrapInboundIn(data)

        self.payload = frame.data
        let inflatedPayload = inflatePayload(allocator: ctx.channel.allocator)! 

        let inflatedFrame = WebSocketFrame(fin: frame.fin, opcode: frame.opcode, data: inflatedPayload)
        _ = ctx.writeAndFlush(self.wrapInboundOut(inflatedFrame))
    }    

    func inflatePayload(allocator: ByteBufferAllocator) -> ByteBuffer? {
        initializeDecoder()
        defer {
            deinitializeDecoder()
        }
        return uncompressPayload(allocator: allocator, flag: Z_NO_FLUSH)
    }

    private func initializeDecoder() {
        stream.zalloc = nil 
        stream.zfree = nil 
        stream.opaque = nil 

        stream.avail_in = 0
        stream.next_in = nil

        let rc = CZlib_inflateInit2(&stream, 15)
        precondition(rc == Z_OK, "Unexpected return from zlib init: \(rc)")
    }

    private func deinitializeDecoder() {
        inflateEnd(&stream)
    }

    func uncompressPayload(allocator: ByteBufferAllocator, flag: Int32) -> ByteBuffer? {
        guard var payload = self.payload, payload.readableBytes > 0 else {
            return nil
        }
        let payloadSize =  payload.readableBytes
        print("payloadSize", payloadSize)
        var outputBuffer = allocator.buffer(capacity: 2)
        repeat {
            var partialOutputBuffer = allocator.buffer(capacity: payload.readableBytes)
            print("partialOutputBuffer", partialOutputBuffer.capacity)
            stream.oneShotInflate(from: &payload, to: &partialOutputBuffer, flag: flag)
            print("partialOutputBuffer.readableBytes", partialOutputBuffer.readableBytes)
            let processedBytes = payloadSize - Int(stream.avail_in)
            payload.moveReaderIndex(to: processedBytes) 
            outputBuffer.write(buffer: &partialOutputBuffer)
            print("stream.avail_in = ", stream.avail_in)
            print("stream.avail_out = ", stream.avail_out)
        } while stream.avail_in > 0
        print("outputBuffer", outputBuffer.readableBytes)
        return outputBuffer 
    }
}

extension z_stream {
    mutating func oneShotInflate(from: inout ByteBuffer, to: inout ByteBuffer, flag: Int32) {
        from.readWithUnsafeMutableReadableBytes { dataPtr in
            let typedPtr = dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            let typedDataPtr = UnsafeMutableBufferPointer(start: typedPtr, count: dataPtr.count)
            self.avail_in = UInt32(typedDataPtr.count)
            self.next_in = typedDataPtr.baseAddress!
            print("1 self.avail_out", self.avail_out)
            let rc = inflateToBuffer(buffer: &to, flag: flag)
            print("3 self.avail_out", self.avail_out)
            print("returned")
            precondition(rc == Z_OK || rc == Z_STREAM_END, "One-shot decompression failed: \(rc)")
            print("typedDataPtr.count = ", typedDataPtr.count)
            return typedDataPtr.count - Int(self.avail_in)
        }
        print("returning")
    }

    private mutating func inflateToBuffer(buffer: inout ByteBuffer, flag: Int32) -> Int32 {
        var rc = Z_OK

        buffer.writeWithUnsafeMutableBytes { outputPtr in
            let typedOutputPtr = UnsafeMutableBufferPointer(start: outputPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                                            count: outputPtr.count)
            
            self.avail_out = UInt32(typedOutputPtr.count)
            self.next_out = typedOutputPtr.baseAddress!
            print("2 self.avail_out", self.avail_out)
            rc = inflate(&self, flag)
            return typedOutputPtr.count - Int(self.avail_out)
        }
        return rc
    }
}
