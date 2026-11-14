// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of HttpServerConnection;

/** @brief Runs a serial accept and dispatch loop with a graceful stop token. */
pub struct HttpServer {}

pub static method(HttpServer) Serve(
  listener: ref mut TcpListener, handler: ref mut HttpServerHandler,
  limits: ref HttpServerLimits, stop: ref NetCancellation, timeout_ns: uint64
) -> Result<Unit, HttpServerError> {
  if timeout_ns == 0u64 || !stop.CanWakeWaiters() || !listener.IsOpen() {
    return HttpServerError{kind: HttpServerErrorKind.InvalidArgument};
  }

  let accept_options = NetOperationOptions{cancellation: stop};
  while !stop.IsCancelled() {
    var accepted = listener.Accept(accept_options);
    if accepted.IsErr() {
      let error = accepted.get_if<NetError>() as NetError;
      if error.kind == NetErrorKind.Cancelled && stop.IsCancelled() {
        break;
      }
      return HttpServerError{kind: HttpServerErrorKind.Transport, socket: error};
    }

    var connection = move(accepted.get_if<TcpConnection>() as TcpConnection);
    let served = HttpServer.ServeConnection(connection, handler, limits, stop, timeout_ns);
    if served.IsErr() {
      return served;
    }
  }

  return UnitValue();
}

static method(HttpServer) ServeConnection(
  connection: ref mut TcpConnection, handler: ref mut HttpServerHandler,
  limits: ref HttpServerLimits, stop: ref NetCancellation, timeout_ns: uint64
) -> Result<Unit, HttpServerError> {
  let start = Instant.Now().ToDurationSinceEpochish().ToNanoseconds();
  let options = NetOperationOptions{deadline: NetDeadline.After(start, timeout_ns), cancellation: stop};
  var opened = HttpServerExchange.ReadPersistent(connection, limits, options);
  // Peer disconnects, malformed heads and idle timeouts retire only that connection.
  if opened.IsErr() {
    return UnitValue();
  }

  var exchange = move(opened.get_if<HttpServerExchange>() as HttpServerExchange);
  while !stop.IsCancelled() {
    exchange.AllowHandlerToFinish();
    let result = handler.Handle(exchange);
    if result.IsErr() {
      let error = result.get_if<HttpServerError>() as HttpServerError;
      if error.kind == HttpServerErrorKind.Protocol || error.kind == HttpServerErrorKind.Transport ||
          error.kind == HttpServerErrorKind.UnexpectedEof {
        break;
      }
      return result;
    }
    if exchange.cell == nil || stop.IsCancelled() {
      break;
    }
    if !exchange.ResponseFinished() {
      return HttpServerError{kind: HttpServerErrorKind.InvalidState};
    }

    let now = Instant.Now().ToDurationSinceEpochish().ToNanoseconds();
    let next_options = NetOperationOptions{deadline: NetDeadline.After(now, timeout_ns), cancellation: stop};
    let next = exchange.NextRequest(next_options);
    if next.IsErr() || !(next.get_if<bool>() as bool) {
      break;
    }
  }

  return UnitValue();
}

method(HttpServerExchange) AllowHandlerToFinish() -> void {
  var state = self.cell as arc<HttpServerState>;
  // Let an admitted handler finish before shutdown; its original deadline still applies.
  state.options = NetOperationOptions{deadline: state.options.deadline};
}

method(HttpServerExchange) ResponseFinished() -> bool {
  return (self.cell as arc<HttpServerState>).response_finished;
}
