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

/** @brief Initial HTTP/2 headers and their stream identity. */
pub struct Http2StreamRequest {
  stream_id: int32;
  verb: string;
  scheme: string;
  authority: string;
  target: string;
  fields: Array<HttpField>;
}

/** @brief Final response head with an optional body producer. */
pub struct Http2StreamResponse {
  status: int32;
  fields: Array<HttpField>;
  has_body: bool;
}

/** @brief Incrementally handle streams on the connection's synchronous I/O loop.
 * @note Calls across different stream IDs may interleave. Return promptly and
 * keep per-stream state by ID. OnClose is called once for every OnHead,
 * including rejected requests, peer resets and connection teardown. Wire
 * error code zero denotes normal stream completion. */
pub interface Http2StreamHandler {
  OnHead(request: ref Http2StreamRequest) -> Result<Unit, Http2Error>;
  OnData(stream_id: int32, data: ref NetBytes) -> Result<Unit, Http2Error>;
  OnEnd(stream_id: int32, trailers: ref Array<HttpField>) -> Result<Http2StreamResponse, Http2Error>;
  Produce(stream_id: int32, output: ref NetMutableBytes) -> Result<int32, Http2Error>;
  OnClose(stream_id: int32, code: uint32) -> void;
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

/** @brief Take accepted TCP and stream HTTP/2 request and response bodies. */
pub static method(Http2Server) ServeStreamingTcp(
  connection: ref mut TcpConnection, provider_file: ref string, handler: Http2StreamHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error>;

/** @brief Stream bodies over a consumed ordered transport and handler.
 * @note OnData borrows the input for the call. Flow-control credit returns
 * after acceptance. OnEnd admits the final response. If it has a body, Produce
 * writes directly into a borrowed frame buffer as peer credit permits.
 * It returns the exact bytes written, or zero at EOF. Failure resets only the
 * affected stream. Set the body budget as for ServeTransport. */
pub static method(Http2Server) ServeStreamingTransport(
  transport: WebSocketTransport, secure: bool, provider_file: ref string, handler: Http2StreamHandler,
  limits: ref Http2Limits, options: ref NetOperationOptions
) -> Result<Unit, Http2Error>;
