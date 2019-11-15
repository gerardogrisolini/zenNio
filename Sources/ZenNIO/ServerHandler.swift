//
//  ServerHandler.swift
//  ZenNIO
//
//  Created by Gerardo Grisolini on 28/02/2019.
//

import Foundation
import NIO
import NIOHTTP1

public enum State {
    case idle
    case waitingForRequestBody
    case sendingResponse
    
    mutating func requestReceived() {
        precondition(self == .idle, "Invalid state for request received: \(self)")
        self = .waitingForRequestBody
    }
    
    mutating func requestComplete() {
        precondition(self == .waitingForRequestBody, "Invalid state for request complete: \(self)")
        self = .sendingResponse
    }
    
    public mutating func responseComplete() {
        precondition(self == .sendingResponse, "Invalid state for response complete: \(self)")
        self = .idle
    }
}

open class ServerHandler: ChannelInboundHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart
    
    public var keepAlive = false
    public var state = State.idle
    public let fileIO: NonBlockingFileIO?
    private var savedBodyBytes: [UInt8] = []
    public var infoSavedRequestHead: HTTPRequestHead? = nil
    private var httpHandler: HttpHandler? = nil
    public var errorHandler: ErrorHandler!


    public init(fileIO: NonBlockingFileIO?, errorHandler: ErrorHandler?) {
        self.fileIO = fileIO
        self.errorHandler = errorHandler ?? defaultError(_:_:_:)
    }
    
    public func completeResponse(_ context: ChannelHandlerContext, trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?) {
        self.state.responseComplete()
        
        let promise = self.keepAlive ? promise : (promise ?? context.eventLoop.makePromise())
        if !self.keepAlive {
            promise!.futureResult.whenComplete { (_: Result<Void, Error>) in
                context.close(promise: nil)
            }
        }
        context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
    }
    
    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        switch reqPart {
        case .head(let request):
            self.infoSavedRequestHead = request
            self.keepAlive = request.isKeepAlive
            self.state.requestReceived()
            savedBodyBytes.removeAll()
        case .body(buffer: let buf):
            self.savedBodyBytes.append(contentsOf: buf.getBytes(at: 0, length: buf.readableBytes)!)
        case .end:
            self.state.requestComplete()
            
            var request = HttpRequest(head: infoSavedRequestHead!, body: savedBodyBytes)
            if let route = ZenNIO.router.getRoute(request: &request) {
                request.clientIp = context.channel.remoteAddress!.description
                request.eventLoop = context.eventLoop
                processRequest(ctx: context, request: request, route: route).whenComplete { res in
                    switch res {
                    case .success(let response):
                        self.processResponse(ctx: context, response: response)
                    case .failure(let err):
                        self.responseError(context, request.head, err)
                    }
                }
                return
            }

            serveFile(ctx: context, request: infoSavedRequestHead!).whenFailure { err in
                self.responseError(context, request.head, err)
            }
        }
    }

    private func processCORS(_ request: HttpRequest, _ response: HttpResponse) {
        guard ZenNIO.cors else { return }
        
        response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
        response.headers.add(name: "Access-Control-Allow-Headers", value: "DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization")
        response.headers.add(name: "Access-Control-Allow-Methods", value: "OPTIONS, POST, PUT, GET, DELETE")
        response.headers.add(name: "Access-Control-Expose-Headers", value: "Content-Length,Content-Range")
    }
    
    private func processSession(_ request: HttpRequest, _ response: HttpResponse, _ filter: Bool) -> Bool {
        if let session = HttpSession.get(authorization: request.authorization, cookies: request.cookies) {
            request.setSession(session)
        } else {
            let session = HttpSession.new()
            request.setSession(session)
            //if request.referer.isEmpty {
                response.addHeader(.setCookie, value: "sessionId=\(session.id); expires=Sat, 01 Jan 2050 00:00:00 UTC; path=/;")
            //}
        }
        if filter {
            return request.isAuthenticated
        }
        return true
    }
    
    private func processRequest(ctx: ChannelHandlerContext, request: HttpRequest, route: Route) -> EventLoopFuture<HttpResponse> {
        let promise = request.eventLoop.makePromise(of: HttpResponse.self)
        request.eventLoop.execute {
            let response = HttpResponse(body: ctx.channel.allocator.buffer(capacity: 0), promise: promise)
            if ZenNIO.session && !self.processSession(request, response, route.filter) {
                response.completed(.unauthorized)
            } else {
                self.processCORS(request, response)
                request.parseRequest()
                route.handler(request, response)
//                if let session = request.session {
//                    ZenNIO.sessions.set(session: session)
//                }
            }
        }
        return promise.futureResult
    }

    public func defaultError(_ ctx: ChannelHandlerContext, _ request: HTTPRequestHead, _ error: Error) -> EventLoopFuture<HttpResponse> {
        var html = ""
        var status: HTTPResponseStatus
        switch error {
        case let e as IOError where e.errnoCode == ENOENT:
            html += "<h3>IOError (not found)</h3>"
            status = .notFound
        case let e as IOError:
            html += "<h3>IOError (other)</h3><h4>\(e.description)</h4>"
            status = .expectationFailed
        default:
            html += "<h3>\(type(of: error)) error</h3>"
            status = .internalServerError
        }

        html = """
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<html>
<head><title>ZenNIO</title></head>
<body>
    <h1>ZenNIO</h1>
    \(html)
</body>
</html>
"""
        let response = HttpResponse(body: ctx.channel.allocator.buffer(capacity: 0))
        response.send(html: html)
        response.completed(status)
        return ctx.eventLoop.makeSucceededFuture(response)
    }
    
    public func httpResponseHead(request: HTTPRequestHead, status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) -> HTTPResponseHead {
        var head = HTTPResponseHead(version: request.version, status: status, headers: headers)
        switch (request.isKeepAlive, request.version.major, request.version.minor) {
        case (true, 1, 0):
            // HTTP/1.0 and the request has 'Connection: keep-alive', we should mirror that
            head.headers.add(name: "Connection", value: "keep-alive")
        case (false, 1, let n) where n >= 1:
            // HTTP/1.1 (or treated as such) and the request has 'Connection: close', we should mirror that
            head.headers.add(name: "Connection", value: "close")
        default:
            // we should match the default or are dealing with some HTTP that we don't support, let's leave as is
            ()
        }
        return head
    }
    
    public func serveFile(ctx: ChannelHandlerContext, request: (HTTPRequestHead)) -> EventLoopFuture<Void> {
        guard let fileIO = self.fileIO else {
            return self.responseErrorAndContinue(ctx, request, HttpError.internalError)
        }

        var path = ZenNIO.htdocsPath + request.uri
        if let index = path.firstIndex(of: "?") {
            path = path[path.startIndex...path.index(before: index)].description
        }

        return fileIO.openFile(path: path, eventLoop: ctx.eventLoop).map { (file, region) -> Void in
            var responseStarted = false
            let response = self.responseHead(request: request, fileRegion: region, contentType: path.contentType)
            return fileIO.readChunked(
                fileRegion: region,
                chunkSize: 32 * 1024,
                allocator: ctx.channel.allocator,
                eventLoop: ctx.eventLoop) { buffer in
                    if !responseStarted {
                        responseStarted = true
                        ctx.write(self.wrapOutboundOut(.head(response)), promise: nil)
                    }
                    return ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                }.flatMap { () -> EventLoopFuture<Void> in
                    let p = ctx.eventLoop.makePromise(of: Void.self)
                    self.completeResponse(ctx, trailers: nil, promise: p)
                    return p.futureResult
                }.flatMapError { error in
                    if !responseStarted {
                        return self.responseErrorAndContinue(ctx, request, error)
                    } else {
                        return ctx.close()
                    }
                }.whenComplete { _ in
                    _ = try? file.close()
                }
        }
    }
    
    private func responseError(_ ctx: ChannelHandlerContext, _ request: HTTPRequestHead, _ error: Error) {
        let response = self.errorHandler(ctx, request, error)
        response.whenSuccess { response in
            self.processResponse(ctx: ctx, response: response)
        }
    }

    private func responseErrorAndContinue(_ ctx: ChannelHandlerContext, _ request: HTTPRequestHead, _ error: Error) -> EventLoopFuture<Void> {
        self.responseError(ctx, request, error)
        let p = ctx.eventLoop.makePromise(of: Void.self)
        self.completeResponse(ctx, trailers: nil, promise: p)
        return ctx.eventLoop.makeSucceededFuture(())
}
    
    open func responseHead(request: HTTPRequestHead, fileRegion region: FileRegion, contentType: String) -> HTTPResponseHead {
        var response = httpResponseHead(request: request, status: .ok)
        response.headers.add(name: "Content-Length", value: "\(region.endIndex)")
        response.headers.add(name: "Content-Type", value: contentType)
        return response
    }
    
    open func processResponse(ctx: ChannelHandlerContext, response: HttpResponse) {
        let head = self.httpResponseHead(request: self.infoSavedRequestHead!, status: response.status, headers: response.headers)
        ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
        ctx.write(self.wrapOutboundOut(.body(.byteBuffer(response.body))), promise: nil)
        self.completeResponse(ctx, trailers: nil, promise: nil)
    }
    
    public func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
    
    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // The remote peer half-closed the channel. At this time, any
            // outstanding response will now get the channel closed, and
            // if we are idle or waiting for a request body to finish we
            // will close the channel immediately.
            switch self.state {
            case .idle, .waitingForRequestBody:
                context.close(promise: nil)
            case .sendingResponse:
                self.keepAlive = false
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
    
    /*
    public func getStaticFile(uri: String) throws -> Data {
        let fileURL = URL(fileURLWithPath: "\(ZenNIO.htdocsPath)/\(uri)")
        do {
            return try Data(contentsOf: fileURL)
        } catch {
            throw HttpError.fileNotFound
        }
    }

    private func processFileRequest(ctx: ChannelHandlerContext, request: HttpRequest) -> EventLoopFuture<HttpResponse> {
        let promise = request.eventLoop.makePromise(of: HttpResponse.self)
        request.eventLoop.execute {
            let response = HttpResponse(body: ctx.channel.allocator.buffer(capacity: 0), promise: promise)

            var path = request.url
            if let index = path.firstIndex(of: "?") {
                path = path[path.startIndex...path.index(before: index)].description
            }

            do {
                let data = try self.getStaticFile(uri: path)
                response.addHeader(.contentType, value: path.contentType)
                response.send(data: data)
                response.completed()
            } catch {
                response.completed(.notFound)
            }
        }
        return promise.futureResult
    }
    */
}
