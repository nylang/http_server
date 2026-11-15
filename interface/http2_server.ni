// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "net_core:net_core.ny";
import "http:http.ny";
import "http:http2.ny";

/** @brief Complete bounded request with its pseudo-fields separated from ordinary headers. */
pub struct Http2ServerRequest {
  stream_id: int32;
  verb: string;
  scheme: string;
  authority: string;
  target: string;
  fields: Array<HttpField>;
  trailers: Array<HttpField>;
  body: ByteBuffer;
}

/** @brief A final HTTP/2 response. Header names are normalized to lowercase. */
pub struct Http2ServerResponse {
  status: int32;
  fields: Array<HttpField>;
  body: ByteBuffer;
}

/** @brief Synchronous handler invoked only after a complete request.
 * @note Return a bodyless response for HEAD and bodyless statuses. The HTTP/2
 * adapter owns framing. An application error resets the affected stream. */
pub interface Http2ServerHandler {
  Handle(request: ref Http2ServerRequest) -> Result<Http2ServerResponse, Http2Error>;
}

/** @brief Drives multiple client streams on one HTTP/2 connection. */
pub struct Http2Server;

/** @brief Take accepted TCP and serve HTTP/2 cleartext prior knowledge. */
pub static method(Http2Server) ServeTcp(
  connection: ref mut TcpConnection, provider_file: ref string, handler: ref mut Http2ServerHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error>;

/** @brief Take an established ordered transport and drive one HTTP/2 connection.
 * @note For encrypted traffic, authenticate and negotiate ALPN h2 before calling
 * and set secure to true. The transport is consumed on failure and success.
 * The supplied deadline and cancellation control connection I/O. */
pub static method(Http2Server) ServeTransport(
  transport: WebSocketTransport, secure: bool, provider_file: ref string,
  handler: ref mut Http2ServerHandler, limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error>;
