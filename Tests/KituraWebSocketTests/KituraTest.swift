/**
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

import LoggerAPI
@testable import KituraWebSocket
@testable import KituraNIO
import Cryptor
import NIO
import NIOHTTP1
import NIOWebSocket

import Foundation
import Dispatch

class KituraTest: XCTestCase {
    
    private static let initOnce: () = {
        PrintLogger.use(colored: true)
    }()
    
    override func setUp() {
        super.setUp()
        KituraTest.initOnce
    }
    
    private static var wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    
    var secWebKey = "test"
    
    // Note: These two paths must only differ by the leading slash
    let servicePathNoSlash = "wstester"
    let servicePath = "/wstester"

    let httpRequestEncoder = HTTPRequestEncoder()
    let httpResponseDecoder = HTTPResponseDecoder()    
    var httpHandler: IncomingResponseHandler? = nil
    func performServerTest(line: Int = #line,
                           asyncTasks: (XCTestExpectation) -> Void...) {
        let server = HTTP.createServer()
        server.allowPortReuse = true 
        do {
            try server.listen(on: 8080)
        
            let requestQueue = DispatchQueue(label: "Request queue")
        
            for (index, asyncTask) in asyncTasks.enumerated() {
                let expectation = self.expectation(line: line, index: index)
                requestQueue.async() {
                    asyncTask(expectation)
                }
            }
        
            waitForExpectations(timeout: 10) { error in
                // blocks test until request completes
                server.stop()
                XCTAssertNil(error)
            }
        }
        catch {
            XCTFail("Test failed. Error=\(error)")
        }
    }
   
    class DataHandler: ChannelInboundHandler {

        public typealias InboundIn = ByteBuffer

        let numberOfFramesExpected: Int
 
        let expectedFrames: [(Bool, Int, Data)]

        var currentFramePayload: [UInt8] = []
        
        var currentFrameLength: Int

        var currentFrameOpcode: Int

        var currentFrameFinal: Bool = false

        var frameNumber: Int = 0

        var firstFragment: Bool = false

        init(expectedFrames: [(Bool, Int, NSData)] {
            self.numberOfFramesExpected = expectedFrames.count
            self.expectedFrames = expectedFrames.map { $0.0, $0.1, Data(referencing: $0.2) }
        }

        func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
            var buffer = self.unwrapInboundIn(data)
            if firstFragment {
               currentFrameOpcode = getFrameOpcode(from: buffer)
               currentFrameLength = getFrameLength(from: buffer)
               currentFrameFinal  = getFrameFinal(from: buffer)
               currentFramePayload.append(buffer.readBytes(length: buffer.readableBytes))
               firstFragment.toggle()
            } else {
                currentPayload.append(buffer.readBytes(length: buffer.readableBytes))
            }
            
            if currentPayload.length == currentFrameLength {
                compareFrames(frameNumber, currentFrameFinal, currentFrameOpcode, currentFramePayload)
                frameNumber += 1
                firstFragment.toggle()
            }
        }

        func getFrameOpcode(buffer: ByteBuffer) {
        }

        func getFrameLength(buffer: ByteBuffer) {
        }

        func comapreFrames(_ frameNumber: Int, _ currentFrameFinal: Bool, _ currentFrameOpcode: Int, _ currentFramePayload: [UInt8]) {
            let (expectedFinal, expectedOpCode, expectedPayload) = expectedFrame[frameNumber]
            XCTAssertEqual(currentFrameFinal, expectedFinal, "Expected message was\(expectedFinal ? "n't" : "") final")
            XCTAssertEqual(currentFrameOpCode, expectedOpCode, "Opcode wasn't \(expectedOpCode). It was \(currentFrameOpcode)")
            XCTAssertEqual(expectedPayload, payload, "The payload [\(payload)] doesn't equal the expected [\(expectedPayload)]")
        }
    } 

    func performTest(framesToSend: [(Bool, Int, NSData)],
                     expectedFrames: [(Bool, Int, NSData)], expectation: XCTestExpectation) {
        let upgradeCompletionExpectation = self.expectation(description: "Upgrade successful")
        guard let channel = sendUpgradeRequest(toPath: servicePath, usingKey: secWebKey, testUpgradeResponse: true, expectation: upgradeCompletionExpectation) else { return }
        usleep(500)
        try! channel.pipeline.remove(handler: httpRequestEncoder)
        try! channel.pipeline.remove(handler: httpResponseDecoder)
        try! channel.pipeline.remove(handler: httpHandler!)
        try! channel.pipeline.add(handler: DataHandler(expectedFrames: expectedFrames), first: true).wait()
        for frameToSend in framesToSend {
            let (finalToSend, opCodeToSend, payloadToSend) = frameToSend 
            try! self.sendFrame(final: finalToSend, withOpcode: opCodeToSend, withPayload: payloadToSend, on: channel)
        }
    }
    
    func register(onPath: String? = nil, closeReason: WebSocketCloseReasonCode, testServerRequest: Bool = false, pingMessage: String? = nil) {
        let service = TestWebSocketService(closeReason: closeReason, testServerRequest: testServerRequest, pingMessage: pingMessage)
        WebSocket.register(service: service, onPath: onPath ?? servicePath)
    }
    
    func sendUpgradeRequest(forProtocolVersion: String? = "13", toPath: String, usingKey: String?, testUpgradeResponse: Bool = false, testUpgradeFailure: Bool = false, expectation: XCTestExpectation) -> Channel? {
        self.httpHandler = IncomingResponseHandler(testSuccess: true, key: usingKey!, expectation: expectation)
        let clientBootstrap = ClientBootstrap(group: MultiThreadedEventLoopGroup(numberOfThreads: 1))
            .channelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEPORT), value: 1)
            .channelInitializer { channel in
                channel.pipeline.add(handler: self.httpRequestEncoder).then {
                    channel.pipeline.add(handler: self.httpResponseDecoder).then {
                        channel.pipeline.add(handler: self.httpHandler!)
                    }
                }
            }

        do {
            let channel = try clientBootstrap.connect(host: "localhost", port: 8080).wait()
            var request = HTTPRequestHead(version: HTTPVersion(major: 1, minor:1), method: HTTPMethod.method(from: "GET"), uri: toPath)
            var headers = HTTPHeaders()
            headers.add(name: "Host", value: "localhost:8080")
            headers.add(name: "Upgrade", value: "websocket")
            headers.add(name: "Connection", value: "Upgrade")
            if let protocolVersion = forProtocolVersion {
                headers.add(name: "Sec-WebSocket-Version", value: protocolVersion)
            }
            if let key = usingKey {
                headers.add(name: "Sec-WebSocket-Key", value: key)
            }
            request.headers = headers
            channel.write(NIOAny(HTTPClientRequestPart.head(request)), promise: nil) 
            try! channel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil))).wait()
            return channel
        } catch {
            XCTFail("Sending the upgrade request failed")
            return nil
        }
    } 

    static func checkUpgradeResponse(_ httpStatusCode: HTTPStatusCode, _ secWebAccept: String, _ forKey: String) {
        
        XCTAssertEqual(httpStatusCode, HTTPStatusCode.switchingProtocols, "Returned status code on upgrade request was \(httpStatusCode) and not \(HTTPStatusCode.switchingProtocols)")
        
        let sha1 = Digest(using: .sha1)
        let key: String = forKey + KituraTest.wsGUID
        let sha1Bytes = sha1.update(string: key)!.final()
        let sha1Data = NSData(bytes: sha1Bytes, length: sha1Bytes.count)
        let secWebAcceptExpected = sha1Data.base64EncodedString(options: .lineLength64Characters)
        
        XCTAssertEqual(secWebAccept, secWebAcceptExpected,
                       "The Sec-WebSocket-Accept header value was [\(secWebAccept)] and not the expected value of [\(secWebAcceptExpected)]")
    }

    func expectation(line: Int, index: Int) -> XCTestExpectation {
        return self.expectation(description: "\(type(of: self)):\(line)[\(index)]")
    }
}

class IncomingResponseHandler: ChannelInboundHandler {

    public typealias InboundIn = HTTPClientResponsePart

    let testFailure: Bool

    let testSuccess: Bool

    let expectation: XCTestExpectation

    let key: String

    public init(testSuccess: Bool = false, testFailure: Bool = false, key: String, expectation: XCTestExpectation) {
        self.expectation = expectation
        self.testSuccess = testSuccess
        self.testFailure = testFailure
        self.key = key
    }

    func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
        let response = self.unwrapInboundIn(data)
        
        switch response {
        case .head(let header):
            let statusCode = HTTPStatusCode(rawValue: Int(header.status.code))!
            let secWebSocketAccept = header.headers["Sec-WebSocket-Accept"]
            if testSuccess {
                KituraTest.checkUpgradeResponse(statusCode, secWebSocketAccept[0], key)
                expectation.fulfill()
            }
        default: break
        }
    }   
}

extension Bool {
    mutating func toggle() {
        self = !self
    }
}
