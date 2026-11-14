// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns connection, parser read-ahead and one HTTP server exchange. */
module HttpServerConnection;
part "request.ny";
part "response.ny";
part "serve.ny";
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
  response_finished: bool;
  persistent: bool;
  close_after_response: bool;
  expect_continue: bool;
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
  return HttpServerExchange.ReadConnection(connection, limits, options, false);
}

pub static method(HttpServerExchange) ReadPersistent(
  connection: ref mut TcpConnection, limits: ref HttpServerLimits, options: ref NetOperationOptions
) -> Result<HttpServerExchange, HttpServerError> {
  return HttpServerExchange.ReadConnection(connection, limits, options, true);
}

static method(HttpServerExchange) ReadConnection(
  connection: ref mut TcpConnection, limits: ref HttpServerLimits, options: ref NetOperationOptions, persistent: bool
) -> Result<HttpServerExchange, HttpServerError> {
  var state = new arc<HttpServerState>{
    connection: move(connection), options: options, limits: limits, persistent: persistent
  };
  let received = state.ReadHead();
  if received.IsErr() || !(received.get_if<bool>() as bool) {
    state.connection.Close();
    return received.IsErr() ? (received.get_if<HttpServerError>() as HttpServerError) :
      HttpServerError{kind: HttpServerErrorKind.UnexpectedEof};
  }

  return HttpServerExchange{cell: state};
}

pub method(HttpServerExchange) NextRequest(options: ref NetOperationOptions) -> Result<bool, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return false;
  }

  var state = cell as arc<HttpServerState>;
  if !state.response_finished {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  state.options = options;
  state.responding = false;
  state.response_finished = false;
  state.close_after_response = false;
  state.expect_continue = false;
  let result = state.ReadHead();
  if result.IsErr() || !(result.get_if<bool>() as bool) {
    self.Close();
  }

  return result;
}

pub method(HttpServerExchange) CloseAfterResponse() -> Result<Unit, HttpServerError> {
  let cell = self.cell;
  if cell == nil || (cell as arc<HttpServerState>).responding {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  var state = cell as arc<HttpServerState>;
  state.close_after_response = true;

  return UnitValue();
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
