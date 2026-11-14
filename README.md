# Nyra HTTP server

Import `http_server:http_server.ny` with the hosted Nyra SDK. The package
uses the existing `http` framing and `net_core` TCP provider. Build the
provider with the net_core native build instructions.

Create a listener with `TcpListener.Listen`. For each exchange call
`HttpServerExchange.Accept(listener, limits, options)`, or use `Read` to
adopt a TCP connection accepted by your application. Inspect `Request()`.
An optional `HttpRoutes` dispatches by exact method and raw path, ignoring
the query. Read decoded request payload with `ReadBody` until it returns
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

Each exchange uses one absolute deadline and cancellation token. Unsupported
or malformed opening requests and terminal I/O errors close the connection.
An application can send a final error response after admitting the head.
For a request with `Expect: 100-continue`, the first body read sends the
interim response. Send a final rejection before reading to skip the interim
response. Route registration validates method and path wire syntax.
Applications may run multiple listeners or hand accepted connections to
their own worker model. TLS can terminate at a reverse proxy.

After authorizing a request and validating its route and Origin, call
`Upgrade` to transfer TCP ownership and preserve any WebSocket bytes read
with the HTTP head.
