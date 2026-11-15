# Nyra HTTP server

Import `http_server:http_server.ny` with the hosted Nyra SDK. The package
uses the existing `http` framing and `net_core` TCP provider. Build the
provider with the net_core native build instructions.

Create a listener with `TcpListener.Listen`. For each exchange call
`HttpServerExchange.Accept(listener, limits, options)`, or use `Read` to
adopt a TCP connection accepted by your application. Inspect `Request()`.
An optional `HttpRoutes` dispatches by method and raw path, ignoring the
query. Register literal paths with `Add` and named single-segment patterns
such as `/files/{name}` with `AddPattern`. A literal match wins. Patterns
are tried in registration order. `MatchTarget` accepts the method and target
from either HTTP/1.1 or HTTP/2 and returns owned capture names and values.
Captures preserve percent escapes such as `%2F`.
Read decoded request payload with `ReadBody` until it returns
zero. Supply `Content-Length` or `Transfer-Encoding: chunked` to
`StartResponse` and stream bytes using `WriteBody`. `FinishResponse`
completes framing and closes the connection.

Read trailers with `RequestTrailerCount` and `RequestTrailerAt` after
the request body is complete. Each trailer is separate from the request
head. To send trailers, declare their names in the response's `Trailer`
header and finish the chunked response with `FinishResponseWithTrailers`.
The shared HTTP framing rules validate inbound and outbound trailer fields.

The original caller-driven `Accept` and `Read` entry points serve one exchange
per connection. To reuse connections, adopt TCP with `ReadPersistent`, finish
the response, and call `NextRequest` with fresh controls. Reuse requires a
fully consumed request and a self-delimited response. Call `CloseAfterResponse`
before starting the response to retire the connection explicitly.

`HttpServer.Serve` runs a serial accept and dispatch loop with a wakeable
cancellation token. Shutdown interrupts idle accept or request-head reads.
An already admitted handler can finish under its original deadline. The
loop retires a connection on protocol, transport or unexpected EOF errors.
Other handler errors end the loop. The
caller owns the listener and can use the lower-level exchange API for a
concurrent worker model.

`HttpServer.ServeTransport` drives a persistent HTTP/1.1 connection on an
already established transport. Its deadline and cancellation cover the whole
connection. Use explicit response framing or a bodyless response.

`HttpServer.ServeConcurrent` provides a pool of 1 to 64 connection
workers. Implement `HttpServerHandlerFactory` to give each worker its own
handler instance. A worker handles every request on its assigned persistent
connection. Once every slot is occupied, new connections wait in the socket
backlog. Cancellation wakes accepts and idle request reads, while handlers
already admitted may finish under their original exchange deadlines.

Use `ReadTransport` to adopt an exclusively owned byte transport after
its handshake, such as an application-provided TLS transport negotiated
for HTTP/1.1. It uses the same transport contract as WebSocket, so an
approved upgrade can hand off that transport together with read-ahead.
The application supplies the server certificate, handshake and ALPN
policy for a TLS transport.

Each exchange uses one absolute deadline and cancellation token. Unsupported
or malformed opening requests and terminal I/O errors close the connection.
An application can send a final error response after admitting the head.
For a request with `Expect: 100-continue`, the first body read sends the
interim response. Send a final rejection before reading to skip the interim
response. Route registration validates method and path wire syntax.
Applications may run multiple listeners or hand accepted connections to
their own worker model. TLS can terminate at a reverse proxy.

After authorizing a request and validating its route and Origin, call
`Upgrade` to transfer transport ownership and preserve any WebSocket bytes read
with the HTTP head.

## HTTP/2

Import `http_server:http2_server.ny` and implement `Http2ServerHandler`.
Pass accepted TCP to `Http2Server.ServeTcp` for cleartext prior knowledge.
`Http2Server.ServeSecure` from `http_tls:https_server.ny` negotiates ALPN
`h2`. Both entry points serve one connection. Handlers run serially in
request completion order while the connection supports multiple active
streams. Limits apply per stream to the request and response body, with a
separate header cap. An oversized request or a handler error resets its
stream. The handler receives the complete body, headers and request trailers.
The initial profile handles regular HTTP requests and final responses.
CONNECT and server push are outside this profile.

Use `ServeStreamingTcp` or `ServeStreamingTransport` with an
`Http2StreamHandler` for larger transfers. `OnHead` is followed by
borrowed `OnData` chunks, then `OnEnd` with any request trailers. Returning
success from `OnData` releases HTTP/2 receive credit for that chunk.
`OnEnd` returns the response head. Mark `has_body` to produce DATA
directly into a frame buffer as the peer's flow-control windows allow.
Callbacks from different streams can interleave on the same connection
thread. Keep callbacks short and release per-stream state in `OnClose`.
The same body budget applies to streaming transfers.

`ServeDuplexTcp` and `ServeDuplexTransport` accept an
`Http2DuplexHandler`. Return the final response from any inbound callback
through `Http2DuplexAction`. Once its headers are sent, the request can
continue to deliver DATA and trailers while the peer reads the response.
The producer returns `Http2DuplexChunk{written: 0, end: false}` to await
another inbound DATA frame or request end. Use `end: true` with the final
chunk, including an empty chunk. The duplex bridge entry point is
`nyra_http2_server_duplex_provider`.

Build the optional server bridge with nghttp2. For example, on macOS:

```sh
cc -std=c11 -fvisibility=hidden -dynamiclib $(pkg-config --cflags libnghttp2) \
  private/native/http2_server.c $(pkg-config --libs libnghttp2) \
  -o /path/to/libnyra_http2_server.dylib
```

On ELF systems use `-fPIC -shared`. On Windows, build a DLL and define
`NGHTTP2_STATICLIB` when linking a static nghttp2 library.
Pass a trusted absolute library path.
The HTTP/1.1 entry points do not load this bridge.
