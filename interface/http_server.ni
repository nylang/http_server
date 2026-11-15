// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "http:http.ny";
import "net_core:net_core.ny";

/** @brief Failure phase with underlying errors where applicable. */
pub enum HttpServerErrorKind {
  InvalidState,
  InvalidArgument,
  Unsupported,
  UnexpectedEof,
  Transport,
  Protocol,
  Upgrade,
  WorkerUnavailable
}

/** @brief One failure from an accepted exchange. */
pub struct HttpServerError {
  kind: HttpServerErrorKind;
  socket: NetError?;
  http: HttpError?;
  websocket: WebSocketError?;
}

/** @brief Head and body parser/writer budgets using the shared HTTP defaults when zero. */
pub struct HttpServerLimits {
  head: HttpHeadLimits;
  request_body: HttpBodyLimits;
  response_body: HttpBodyLimits;
}

/** @brief Owned routes comparing methods and raw path segments case sensitively. */
pub struct HttpRoutes;

/** @brief Start an empty route table. */
pub static method(HttpRoutes) New() -> HttpRoutes;

/** @brief Register a literal path and method or report an invalid or duplicate route. */
pub method(HttpRoutes) Add(verb: ref string, path: ref string, id: int32) -> bool;

/** @brief Register a path pattern with one or more whole-segment {name} captures.
 * @note Names must be unique ASCII identifiers. Each capture matches one nonempty
 * raw segment. Equivalent patterns for the same method are rejected. Literal
 * routes take priority, then patterns are tried in registration order. */
pub method(HttpRoutes) AddPattern(verb: ref string, path: ref string, id: int32) -> bool;

/** @brief An owned named capture from a request's raw path. */
pub struct HttpRouteParam {
  name: string;
  value: string;
}

/** @brief Matched route ID and owned captures in path order. */
pub struct HttpRouteMatch {
  id: int32;
  params: Array<HttpRouteParam>;
}

/** @brief Find the route for a parsed request. The query string does not participate. */
pub method(HttpRoutes) Match(request: ref HttpHead) -> int32?;

/** @brief Find a route and captures for the raw origin-form target of a parsed request.
 * @note Pass the HTTP/1.1 method/target or HTTP/2 :method/:path. The query is
 * ignored and percent escapes are preserved, including an encoded slash. */
pub method(HttpRoutes) MatchTarget(verb: ref string, target: ref string) -> HttpRouteMatch?;

/** @brief Owns an ordered connection and one active HTTP/1.1 exchange on the caller thread. */
pub struct HttpServerExchange;

/** @brief The connection has one owner. */
pub method(HttpServerExchange) operator copy() -> HttpServerExchange = delete;

/** @brief Transfer the connection and invalidate the source. */
pub method(HttpServerExchange) operator move() -> HttpServerExchange;

/** @brief Close the connection at the end of the exchange lifetime. */
pub method(HttpServerExchange) operator drop() -> void;

/** @brief Accept TCP then read and admit the request head and framing. */
pub static method(HttpServerExchange) Accept(
  listener: ref mut TcpListener, limits: ref HttpServerLimits, options: ref NetOperationOptions
) -> Result<HttpServerExchange, HttpServerError>;

/** @brief Adopt an accepted TCP connection and read its HTTP/1.1 head.
 * @note Consumption applies on failure as well. The sole supported expectation is 100-continue.
 * The supplied controls apply until the connection closes or upgrades. */
pub static method(HttpServerExchange) Read(
  connection: ref mut TcpConnection, limits: ref HttpServerLimits, options: ref NetOperationOptions
) -> Result<HttpServerExchange, HttpServerError>;

/** @brief Adopt TCP and opt into sequential HTTP/1.1 keep-alive. */
pub static method(HttpServerExchange) ReadPersistent(
  connection: ref mut TcpConnection, limits: ref HttpServerLimits, options: ref NetOperationOptions
) -> Result<HttpServerExchange, HttpServerError>;

/** @brief Adopt an already established ordered byte transport for HTTP/1.1.
 * @note Pass an exclusively owned transport. For TLS, finish the handshake and
 * select HTTP/1.1 before calling. The exchange consumes the transport on failure
 * as well as success and can hand it off to WebSocket. */
pub static method(HttpServerExchange) ReadTransport(
  transport: WebSocketTransport, limits: ref HttpServerLimits,
  options: ref NetOperationOptions, persistent: bool, {require_framed_response: bool = false}
) -> Result<HttpServerExchange, HttpServerError>;

/** @brief Read the next request after finishing the previous response.
 * @returns False on a retired connection or EOF between requests. An incomplete head is an error.
 * @note The supplied controls apply to the new request and its response. */
pub method(HttpServerExchange) NextRequest(options: ref NetOperationOptions) -> Result<bool, HttpServerError>;

/** @brief Require connection closure after this response. Call before StartResponse. */
pub method(HttpServerExchange) CloseAfterResponse() -> Result<Unit, HttpServerError>;

/** @brief Return the parsed request. A default exchange returns an invalid head. */
pub method(HttpServerExchange) Request() -> HttpHead;

/** @brief Read decoded request bytes into the caller's buffer.
 * @returns Positive payload count, zero at the exact body boundary or a terminal error.
 * @note The caller must supply a nonempty buffer. The first read sends 100 Continue when
 * requested and a body is expected. Earlier payload is partial until zero. */
pub method(HttpServerExchange) ReadBody(output: ref NetMutableBytes) -> Result<intptr, HttpServerError>;

/** @brief Return the number of request trailers after the body is complete. */
pub method(HttpServerExchange) RequestTrailerCount() -> Result<int32, HttpServerError>;

/** @brief Return an owned request trailer by zero-based wire order after body completion. */
pub method(HttpServerExchange) RequestTrailerAt(index: int32) -> Result<HttpField, HttpServerError>;

/** @brief Start one final HTTP response. The library adds Connection: close when retiring the connection.
 * @note Provide Content-Length for fixed responses or Transfer-Encoding: chunked
 * for streamed responses. HEAD and bodyless statuses honor shared HTTP framing.
 * Declare any chunked response trailers in the Trailer header.
 * The caller may start an error response without draining the request. */
pub method(HttpServerExchange) StartResponse(
  status: int32, reason: ref string, fields: ref <HttpField>[]
) -> Result<Unit, HttpServerError>;

/** @brief Write all supplied response payload bytes, stopping on terminal failure. */
pub method(HttpServerExchange) WriteBody(input: ref NetBytes) -> Result<Unit, HttpServerError>;

/** @brief Finish response framing; eligible persistent connections can receive another request. */
pub method(HttpServerExchange) FinishResponse() -> Result<Unit, HttpServerError>;

/** @brief Finish a chunked response with declared, validated trailers.
 * @note An invalid or undeclared trailer closes the exchange with a protocol error. */
pub method(HttpServerExchange) FinishResponseWithTrailers(trailers: ref <HttpField>[]) -> Result<Unit, HttpServerError>;

/** @brief Transfer the connection to an approved WebSocket upgrade, preserving HTTP read-ahead.
 * @note Perform route, Origin and authorization checks before calling. */
pub method(HttpServerExchange) Upgrade(limits: ref WebSocketLimits) -> Result<WebSocket, HttpServerError>;

/** @brief Immediately close a remaining connection. */
pub method(HttpServerExchange) Close() -> void;

/** @brief Synchronous handler for one admitted request.
 * @note Finish the response or hand off the connection before returning success. */
pub interface HttpServerHandler {
  Handle(exchange: ref mut HttpServerExchange) -> Result<Unit, HttpServerError>;
}

/** @brief Creates an independently owned handler for each connection worker.
 * @note Called synchronously in worker index order during startup. Each
 * handler is then used exclusively by its worker. Synchronize any shared state. */
pub interface HttpServerHandlerFactory {
  Create(worker_index: int32) -> Result<HttpServerHandler, HttpServerError>;
}

/** @brief HTTP/1.1 service loops over the caller's listening socket. */
pub struct HttpServer;

/** @brief Accept and serve connections until stop is cancelled.
 * @note A wakeable stop token interrupts idle accepts or request-head reads.
 * An active handler may finish under its own per-exchange deadline. Transport
 * errors, malformed input and unexpected EOF retire the affected connection.
 * Other handler errors stop the loop. The caller retains the listening socket. */
pub static method(HttpServer) Serve(
  listener: ref mut TcpListener, handler: ref mut HttpServerHandler,
  limits: ref HttpServerLimits, stop: ref NetCancellation, timeout_ns: uint64
) -> Result<Unit, HttpServerError>;

/** @brief Serve HTTP/1.1 with a fixed pool of 1..64 connection workers.
 * @note The caller retains the listener. Admission pauses when all slots are
 * occupied. Accepted sockets are handed to a worker and kept there for all
 * persistent requests. When stop is cancelled, admitted handlers can finish
 * under their exchange deadlines. The first fatal handler or listener error
 * cancels stop and is returned after the workers exit. */
pub static method(HttpServer) ServeConcurrent(
  listener: ref mut TcpListener, handler_factory: ref mut HttpServerHandlerFactory, workers: int32,
  limits: ref HttpServerLimits, stop: ref NetCancellation, timeout_ns: uint64
) -> Result<Unit, HttpServerError>;
