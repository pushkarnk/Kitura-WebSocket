import NIO
import NIOWebSocket

class WebsocketInflater : ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame 
    typealias InboundOut = WebSocketFrame
}
