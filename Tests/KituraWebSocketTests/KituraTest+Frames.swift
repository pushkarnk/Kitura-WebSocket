/**
         irint(data.getBytes(at: 0, length: data.readableBytes))
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import XCTest

@testable import KituraWebSocket
import LoggerAPI
import NIO

import Foundation
#if os(Linux)
    import Glibc
#endif

extension KituraTest {
    
    var opcodeBinary: Int { return 2 }
    var opcodeClose: Int { return 8 }
    var opcodeContinuation: Int { return 0 }
    var opcodePing: Int { return 9 }
    var opcodePong: Int { return 10 }
    var opcodeText: Int { return 1 }

    func payload(closeReasonCode: WebSocketCloseReasonCode) -> NSData {
        var tempReasonCodeToSend = UInt16(closeReasonCode.code())
        var reasonCodeToSend: UInt16
        #if os(Linux)
            reasonCodeToSend = Glibc.htons(tempReasonCodeToSend)
        #else
            reasonCodeToSend = CFSwapInt16HostToBig(tempReasonCodeToSend)
        #endif
    
        let payload = NSMutableData()
        let asBytes = UnsafeMutablePointer(&reasonCodeToSend)
        payload.append(asBytes, length: 2)
    
        return payload
    }   
    
    func payload(text: String) -> NSData {
        let result = NSMutableData()
    
        let utf8Length = text.lengthOfBytes(using: .utf8)
        var utf8: [CChar] = Array<CChar>(repeating: 0, count: utf8Length + 10) // A little bit of padding
        guard text.getCString(&utf8, maxLength: utf8Length + 10, encoding: .utf8)  else {
            return result
        }

        result.append(&utf8, length: utf8Length)

        return result
    }
    
    func sendFrame(final: Bool, withOpcode: Int, withMasking: Bool=true, withPayload: NSData, on channel: Channel) {
        var buffer = channel.allocator.buffer(capacity: 8) 
        
        var header = createFrameHeader(final: final, withOpcode: withOpcode, withMasking: withMasking,
                          payloadLength: withPayload.length, channel: channel)

        buffer.write(buffer: &header) 
        var intMask: UInt32
            
        #if os(Linux)
            intMask = UInt32(random())
        #else
            intMask = arc4random()
        #endif
        var mask: [UInt8] = [0, 0, 0, 0]
        #if swift(>=4.1)
        UnsafeMutableRawPointer(mutating: mask).copyMemory(from: &intMask, byteCount: mask.count)
        #else
        UnsafeMutableRawPointer(mutating: mask).copyBytes(from: &intMask, count: mask.count)
        #endif
        buffer.write(bytes: mask)
        let payloadBytes = withPayload.bytes.bindMemory(to: UInt8.self, capacity: withPayload.length)
        
        for i in 0 ..< withPayload.length {
            var bytes = [UInt8](repeating: 0, count: 1) 
            bytes[0] = payloadBytes[i] ^ mask[i % 4]
            buffer.write(bytes: bytes)
        }
        do {
            try channel.writeAndFlush(buffer).wait() 
        }
        catch {
            XCTFail("Failed to send a frame. Error=\(error)")
        }
    }
    
    private func createFrameHeader(final: Bool, withOpcode: Int, withMasking: Bool, payloadLength: Int, channel: Channel) -> ByteBuffer {
       
        var buffer = channel.allocator.buffer(capacity: 8) 
        var bytes: [UInt8] = [(final ? 0x80 : 0x00) | UInt8(withOpcode), 0, 0,0,0,0,0,0,0,0]
        var length = 1
        
        if payloadLength < 126 {
            bytes[1] = UInt8(payloadLength)
            length += 1
        } else if payloadLength <= Int(UInt16.max) {
            bytes[1] = 126
            let tempPayloadLengh = UInt16(payloadLength)
            var payloadLengthUInt16: UInt16
            #if os(Linux)
                payloadLengthUInt16 = Glibc.htons(tempPayloadLengh)
            #else
                payloadLengthUInt16 = CFSwapInt16HostToBig(tempPayloadLengh)
            #endif
            let asBytes = UnsafeMutablePointer(&payloadLengthUInt16)
            #if swift(>=4.1)
            (UnsafeMutableRawPointer(mutating: bytes)+length+1).copyMemory(from: asBytes, byteCount: 2)
            #else
            (UnsafeMutableRawPointer(mutating: bytes)+length+1).copyBytes(from: asBytes, count: 2)
            #endif
            length += 3
        } else {
            bytes[1] = 127
            let tempPayloadLengh = UInt32(payloadLength)
            var payloadLengthUInt32: UInt32
            #if os(Linux)
                payloadLengthUInt32 = Glibc.htonl(tempPayloadLengh)
            #else
                payloadLengthUInt32 = CFSwapInt32HostToBig(tempPayloadLengh)
            #endif
            let asBytes = UnsafeMutablePointer(&payloadLengthUInt32)
            #if swift(>=4.1)
            (UnsafeMutableRawPointer(mutating: bytes)+length+5).copyMemory(from: asBytes, byteCount: 4)
            #else
            (UnsafeMutableRawPointer(mutating: bytes)+length+5).copyBytes(from: asBytes, count: 4)
            #endif
            length += 9 
        }
        if withMasking {
            bytes[1] |= 0x80
        }
        buffer.write(bytes: Array(bytes[0..<length]))
        return buffer
    }
}

class WebSocketClientHandler: ChannelInboundHandler {

    public typealias InboundIn = ByteBuffer

    let numberOfFramesExpected: Int

    let expectedFrames: [(Bool, Int, NSData)]

    var currentFramePayload: [UInt8] = []
    
    var currentFrameLength: Int = 0

    var currentFrameOpcode: Int = -1

    var currentFrameFinal: Bool = false

    var frameNumber: Int = 0

    var firstFragment: Bool = true 

    var expectation: XCTestExpectation

    init(expectedFrames: [(Bool, Int, NSData)], expectation: XCTestExpectation) {
        self.numberOfFramesExpected = expectedFrames.count
        self.expectedFrames = expectedFrames
        self.expectation = expectation
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        var buffer = self.unwrapInboundIn(data)
        decodeFrame(from: buffer)
    }

    private func decodeFrame(from data: ByteBuffer) {
        var buffer = data
        if firstFragment {
           var numberOfBytesRead = 0
           guard let firstByte =  buffer.readBytes(length: 1)?[0] else {
               XCTFail("Received empty data from the server")
               return
           }
           (currentFrameFinal, currentFrameOpcode) = getFrameFinalAndOpcode(from: firstByte)
           (currentFrameLength, numberOfBytesRead) = getFrameLength(from: buffer)
           _ = buffer.readBytes(length: numberOfBytesRead)
           currentFramePayload += buffer.readBytes(length: min(currentFrameLength, buffer.readableBytes)) ?? []
           firstFragment.toggle()
        } else {
            currentFramePayload += buffer.readBytes(length: buffer.readableBytes) ?? []
        }
        if currentFramePayload.count == currentFrameLength {
            let currentFramePayloadPtr = UnsafeBufferPointer(start: &currentFramePayload, count: currentFramePayload.count)
            let currentPayloadData = NSData(data: Data(buffer: currentFramePayloadPtr))

            compareFrames(frameNumber, currentFrameFinal, currentFrameOpcode, currentPayloadData)
            frameNumber += 1
            firstFragment.toggle()
            currentFramePayload = []
            if frameNumber == numberOfFramesExpected {
                expectation.fulfill()
            } else if buffer.readableBytes > 0 {
                decodeFrame(from: buffer)
            }
        }
    }

    func getFrameFinalAndOpcode(from byte: UInt8) -> (Bool, Int) {
        return (byte & 0x80 != 0, Int(byte & 0x7f))
    }

    func getFrameLength(from buffer: ByteBuffer) -> (Int, Int) {
        let onFailure = (-1, 0)
        var position = buffer.readerIndex
        var numberOfBytesConsumed = 0
        guard let payloadLen = buffer.getBytes(at: position, length: 1)?[0] else {
            XCTFail("Payload length not received")
            return onFailure
        }
        guard payloadLen & 0x80 == 0 else {
            XCTFail("The server isn't suppose to send masked frames")
            return onFailure
        }
        position += 1
        numberOfBytesConsumed += 1
        var length = Int(payloadLen)
        if length == 126 {
            guard let networkOrderedUInt16 = buffer.getInteger(at: position, endianness: .big, as: UInt16.self) else {
                XCTFail("Payload length not received")
                return onFailure
            }
            length = Int(networkOrderedUInt16)
            position += 2
            numberOfBytesConsumed += 2
        } else if length == 127 {
            position += 4
            guard let networkOrderedUInt32 = buffer.getInteger(at: position, endianness: .big, as: UInt32.self) else {
                XCTFail("Payload length not received")
                return onFailure
            }
            length = Int(networkOrderedUInt32)
            numberOfBytesConsumed += 8
        }    
        return (length, numberOfBytesConsumed)
    }
   
    public func errorCaught(ctx: ChannelHandlerContext, error: Error) {
        print(error)
    }

    func compareFrames(_ frameNumber: Int, _ currentFrameFinal: Bool, _ currentFrameOpcode: Int, _ currentFramePayload: NSData) {
        let (expectedFinal, expectedOpCode, expectedPayload) = expectedFrames[frameNumber]
        XCTAssertEqual(currentFrameFinal, expectedFinal, "Expected message was\(expectedFinal ? "n't" : "") final")
        XCTAssertEqual(currentFrameOpcode, expectedOpCode, "Opcode wasn't \(expectedOpCode). It was \(currentFrameOpcode)")
        XCTAssertEqual(currentFramePayload, expectedPayload, "The payload [\(currentFramePayload)] doesn't equal the expected [\(expectedPayload)]")
    }
}
