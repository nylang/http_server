// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns connection, parser read-ahead and one HTTP server exchange. */
module HttpServerConnection;
part "request.ny";
part "response.ny";
import "stdlib:stdlib.ny";
import "http:http.ny";
import "net_core:net_core.ny";
import "interface/http_server.ni";

struct HttpServerState {
  connection: TcpConnection;
  options: NetOperationOptions;
  limits: HttpServerLimits;
  head: HttpHead;
  decoder: HttpBodyDecoder;
  writer: HttpBodyWriter;
  responding: bool;
  prefix: NetBuffer;
  offset: intptr;
}

/** @brief Move-only owner of accepted connection state. */
pub struct HttpServerExchange {
  cell: arc<HttpServerState>?;
}

pub method(HttpServerExchange) operator move() -> HttpServerExchange {
  let cell = self.cell;
  self.cell = nil;

  return HttpServerExchange{cell: cell};
}

pub method(HttpServerExchange) operator drop() -> void {
  self.Close();
}

pub method(HttpServerExchange) Close() -> void {
  let cell = self.cell;
  self.cell = nil;
  if cell != nil {
    var state = cell as arc<HttpServerState>;
    state.connection.Close();
  }
}

pub method(HttpServerExchange) Request() -> HttpHead {
  let cell = self.cell;
  if cell == nil {
    return HttpHead{};
  }

  return (cell as arc<HttpServerState>).head;
}

pub static method(HttpServerExchange) Accept(
  listener: ref mut TcpListener, limits: ref HttpServerLimits, options: ref NetOperationOptions
) -> Result<HttpServerExchange, HttpServerError> {
  var result = listener.Accept(options);
  if result.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Transport, socket: result.get_if<NetError>()};
  }

  var connection = move(result.get_if<TcpConnection>() as TcpConnection);
  return HttpServerExchange.Read(connection, limits, options);
}

pub static method(HttpServerExchange) Read(
  connection: ref mut TcpConnection, limits: ref HttpServerLimits, options: ref NetOperationOptions
) -> Result<HttpServerExchange, HttpServerError> {
  var state = new arc<HttpServerState>{connection: move(connection), options: options, limits: limits};
  let received = state.ReadHead();
  if received.IsErr() {
    state.connection.Close();
    return received.get_if<HttpServerError>() as HttpServerError;
  }

  return HttpServerExchange{cell: state};
}

method(HttpServerState) Control() -> Result<Unit, HttpServerError> {
  let result = self.options.Check(Instant.Now().ToDurationSinceEpochish().ToNanoseconds());
  if result.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Transport, socket: result.get_if<NetError>()};
  }

  return UnitValue();
}

method(HttpServerState) Send(bytes: ref NetBytes) -> Result<Unit, HttpServerError> {
  var offset: intptr = 0;
  while offset < bytes.Len() {
    let rest = bytes.Slice(offset, bytes.Len() - offset).get_if<NetBytes>() as NetBytes;
    let sent = self.connection.Write(rest, self.options);
    if sent.IsErr() {
      return HttpServerError{kind: HttpServerErrorKind.Transport, socket: sent.get_if<NetError>()};
    }

    let count = sent.get_if<intptr>() as intptr;
    if count <= 0ip {
      return HttpServerError{kind: HttpServerErrorKind.UnexpectedEof};
    }
    offset += count;
  }

  return UnitValue();
}
