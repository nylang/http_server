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
  Upgrade
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

/** @brief Owned exact-match routes. Routes compare method and raw path case sensitively. */
pub struct HttpRoutes;

/** @brief Start an empty route table. */
pub static method(HttpRoutes) New() -> HttpRoutes;

/** @brief Register a literal path and method or report an invalid or duplicate route. */
pub method(HttpRoutes) Add(verb: ref string, path: ref string, id: int32) -> bool;

/** @brief Find the route for a parsed request. The query string does not participate. */
pub method(HttpRoutes) Match(request: ref HttpHead) -> int32?;

/** @brief Owns a TCP connection for one HTTP/1.1 exchange on the caller thread. */
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

/** @brief Start one final HTTP response. The library adds Connection: close.
 * @note Provide Content-Length for fixed responses or Transfer-Encoding: chunked
 * for streamed responses. HEAD and bodyless statuses honor shared HTTP framing.
 * Declare any chunked response trailers in the Trailer header.
 * The caller may start an error response without draining the request. */
pub method(HttpServerExchange) StartResponse(
  status: int32, reason: ref string, fields: ref <HttpField>[]
) -> Result<Unit, HttpServerError>;

/** @brief Write all supplied response payload bytes, stopping on terminal failure. */
pub method(HttpServerExchange) WriteBody(input: ref NetBytes) -> Result<Unit, HttpServerError>;

/** @brief Finish response framing and close the connection. */
pub method(HttpServerExchange) FinishResponse() -> Result<Unit, HttpServerError>;

/** @brief Finish a chunked response with declared, validated trailers and close the connection.
 * @note An invalid or undeclared trailer closes the exchange with a protocol error. */
pub method(HttpServerExchange) FinishResponseWithTrailers(trailers: ref <HttpField>[]) -> Result<Unit, HttpServerError>;

/** @brief Upgrade an application-approved request, preserving HTTP read-ahead.
 * @note Perform route, Origin and authorization checks before calling. */
pub method(HttpServerExchange) Upgrade(limits: ref WebSocketLimits) -> Result<WebSocket, HttpServerError>;

/** @brief Immediately close a remaining connection. */
pub method(HttpServerExchange) Close() -> void;
