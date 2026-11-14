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

This caller-driven HTTP/1.1 profile serves one exchange per connection.
Each exchange uses one absolute deadline and cancellation token. Unsupported
or malformed opening requests and terminal I/O errors close the connection.
An application can send a final error response after admitting the head.
Applications may run multiple listeners or hand accepted connections to
their own worker model. TLS can terminate at a reverse proxy.

After authorizing a request and validating its route and Origin, call
`Upgrade` to transfer TCP ownership and preserve any WebSocket bytes read
with the HTTP head.
