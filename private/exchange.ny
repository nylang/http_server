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
import "private/worker_queue.ny";

struct HttpServerState {
  transport: WebSocketTransport;
  options: NetOperationOptions;
  limits: HttpServerLimits;
  head: HttpHead;
  decoder: HttpBodyDecoder;
  writer: HttpBodyWriter;
  responding: bool;
  response_finished: bool;
  persistent: bool;
  require_framed_response: bool;
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
    state.transport.Abort();
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
  return HttpServerExchange.ReadTransport(HttpServerTcp{connection: move(connection)}, limits, options, false);
}

pub static method(HttpServerExchange) ReadPersistent(
  connection: ref mut TcpConnection, limits: ref HttpServerLimits, options: ref NetOperationOptions
) -> Result<HttpServerExchange, HttpServerError> {
  return HttpServerExchange.ReadTransport(HttpServerTcp{connection: move(connection)}, limits, options, true);
}

pub static method(HttpServerExchange) ReadTransport(
  transport: WebSocketTransport, limits: ref HttpServerLimits, options: ref NetOperationOptions,
  persistent: bool, {require_framed_response: bool = false}
) -> Result<HttpServerExchange, HttpServerError> {
  var state = new arc<HttpServerState>{
    transport: transport, options: options, limits: limits, persistent: persistent,
    require_framed_response: require_framed_response
  };
  let received = state.ReadHead();
  if received.IsErr() || !(received.get_if<bool>() as bool) {
    state.transport.Abort();
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
  if bytes.Len() == 0ip {
    return UnitValue();
  }

  let sent = self.transport.WriteAll(bytes, self.options);
  if sent.IsErr() {
    return HttpServerError.FromTransport(sent.get_if<WebSocketError>() as WebSocketError);
  }

  return UnitValue();
}

static method(HttpServerError) FromTransport(error: ref WebSocketError) -> HttpServerError {
  if error.kind == WebSocketErrorKind.UnexpectedEof {
    return HttpServerError{kind: HttpServerErrorKind.UnexpectedEof};
  }

  return HttpServerError{kind: HttpServerErrorKind.Transport, socket: error.network_error, websocket: error};
}

// The installed transport owns transport I/O and can transfer directly to WebSocket.
pub struct HttpServerTcp implements WebSocketTransport {
  connection: TcpConnection;
}

@override
method(HttpServerTcp) Read(buffer: ref NetMutableBytes, options: ref NetOperationOptions) -> Result<intptr, WebSocketError> {
  let read = self.connection.Read(buffer, options);
  if read.IsErr() {
    return WebSocketError{kind: WebSocketErrorKind.Transport, network_error: read.get_if<NetError>()};
  }

  return read.get_if<intptr>() as intptr;
}

@override
method(HttpServerTcp) WriteAll(buffer: ref NetBytes, options: ref NetOperationOptions) -> Result<Unit, WebSocketError> {
  var offset: intptr = 0;
  while offset < buffer.Len() {
    let rest = buffer.Slice(offset, buffer.Len() - offset).get_if<NetBytes>() as NetBytes;
    let sent = self.connection.Write(rest, options);
    if sent.IsErr() {
      return WebSocketError{kind: WebSocketErrorKind.Transport, network_error: sent.get_if<NetError>()};
    }

    let count = sent.get_if<intptr>() as intptr;
    if count <= 0ip {
      return WebSocketError{kind: WebSocketErrorKind.UnexpectedEof};
    }
    offset += count;
  }

  return UnitValue();
}

@override
method(HttpServerTcp) Abort() -> void {
  self.connection.Close();
}
