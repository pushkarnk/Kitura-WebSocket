import XCTest
import Foundation
import NIO
import CZlib

@testable import KituraWebSocket

class WebSocketDeflaterTests: KituraTest {

    static var allTests: [(String, (WebSocketDeflaterTests) -> () throws -> Void)] {
        return [
            ("testDeflateAndInflate", testDeflateAndInflate)
        ]
    }

    func testDeflateAndInflate() {
        testWithString("a")
        testWithString("xy")
        testWithString("abc")
        testWithString("abcd")
        testWithString("0000")
        testWithString("skfjsdlkjfldkjioroi32j423kljl213kj4lk32j4lk2j4kl32j4lk32j4lk3242")
        testWithString("0000000000000000000000000000000000000000000000000000")
        testWithString("1nkp12p032nn1l1o1knfk;0i0nju]ijijkjkj1121212100000000000000000fsfefdf12121212121fdgfgfgfgfgf")
        testWithString("abcdefghijklmnopqrstuvwxyz0123456789")
        testWithString(String(repeating: "quick brown fox jumps over the lazy dog", count: 100))
    }

    func testWithString(_ input: String) {
        var buffer = ByteBufferAllocator().buffer(capacity: 1)
        buffer.write(string: input)
        let deflater = WebsocketDeflater()
        deflater.payload = buffer
        let deflatedBuffer = deflater.deflatePayload(allocator: ByteBufferAllocator())!
        print("deflated buffer", deflatedBuffer.readableBytes)
        let inflater = WebsocketInflater()
        inflater.payload = deflatedBuffer
        var inflatedBuffer = inflater.inflatePayload(allocator: ByteBufferAllocator())!
        let output = inflatedBuffer.readString(length: inflatedBuffer.readableBytes)
        XCTAssertEqual(output, input)
    }
         
}

