// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of HttpServerConnection;

method(HttpServerState) ReadHead() -> Result<bool, HttpServerError> {
  let control = self.Control();
  if control.IsErr() {
    return control.get_if<HttpServerError>() as HttpServerError;
  }

  var made = HttpHeadParser.NewRequest(self.limits.head);
  if made.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: made.get_if<HttpError>()};
  }

  var parser = move(made.get_if<HttpHeadParser>() as HttpHeadParser);
  var started = false;
  while !parser.IsComplete() {
    if self.offset == self.prefix.Len() {
      let received = self.FillPrefix();
      if received.IsErr() {
        return received.get_if<HttpServerError>() as HttpServerError;
      }
      if (received.get_if<intptr>() as intptr) == 0ip {
        if started {
          return HttpServerError{kind: HttpServerErrorKind.UnexpectedEof};
        }
        return false;
      }
    }

    let input = self.prefix.Bytes().Slice(self.offset, self.prefix.Len() - self.offset).get_if<NetBytes>() as NetBytes;
    let parsed = parser.Push(input);
    if parsed.IsErr() {
      return HttpServerError{kind: HttpServerErrorKind.Protocol, http: parsed.get_if<HttpError>()};
    }
    self.offset += parsed.get_if<intptr>() as intptr;
    started = true;
  }

  let parsed = parser.Head();
  if parsed.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: parsed.get_if<HttpError>()};
  }

  let head = parsed.get_if<HttpHead>() as HttpHead;
  if head.MinorVersion() != 1 {
    return HttpServerError{kind: HttpServerErrorKind.Unsupported};
  }

  var i: int32 = 0;
  while i < head.FieldCount() {
    let field = head.FieldAt(i).get_if<HttpField>() as HttpField;
    if field.name.EqualAsciiIgnoreCase("Expect") {
      if self.expect_continue || !field.value.EqualAsciiIgnoreCase("100-continue") {
        return HttpServerError{kind: HttpServerErrorKind.Unsupported};
      }
      self.expect_continue = true;
    }
    i += 1;
  }

  var body = HttpBodyDecoder.New(head, self.limits.request_body);
  if body.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: body.get_if<HttpError>()};
  }

  self.head = head;
  self.decoder = move(body.get_if<HttpBodyDecoder>() as HttpBodyDecoder);
  self.expect_continue = self.expect_continue && !self.decoder.IsComplete();
  return true;
}

method(HttpServerState) FillPrefix() -> Result<intptr, HttpServerError> {
  var scratch: <uint8>[8192] = <uint8>[8192]{};
  let buffer = NetMutableBytes.FromRaw(&mut scratch[0], 8192ip).get_if<NetMutableBytes>() as NetMutableBytes;
  let received = self.connection.Read(buffer, self.options);
  if received.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Transport, socket: received.get_if<NetError>()};
  }

  let count = received.get_if<intptr>() as intptr;
  let bytes = buffer.AsReadOnly().Slice(0ip, count).get_if<NetBytes>() as NetBytes;
  let held = NetBuffer.CopyFrom(bytes);
  if held.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Transport, socket: held.get_if<NetError>()};
  }

  self.prefix = held.get_if<NetBuffer>() as NetBuffer;
  self.offset = 0ip;
  return count;
}

pub method(HttpServerExchange) ReadBody(output: ref NetMutableBytes) -> Result<intptr, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }
  if output.Len() <= 0ip {
    return HttpServerError{kind: HttpServerErrorKind.InvalidArgument};
  }

  var state = cell as arc<HttpServerState>;
  if state.responding {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  let result = state.ReadBodyChunk(output);
  if result.IsErr() {
    self.Close();
  }

  return result;
}

method(HttpServerState) ReadBodyChunk(output: ref NetMutableBytes) -> Result<intptr, HttpServerError> {
  let control = self.Control();
  if control.IsErr() {
    return control.get_if<HttpServerError>() as HttpServerError;
  }

  if self.expect_continue {
    let response = self.Send(NetBytes.FromString("HTTP/1.1 100 Continue\r\n\r\n"));
    if response.IsErr() {
      return response.get_if<HttpServerError>() as HttpServerError;
    }
    self.expect_continue = false;
  }

  while !self.decoder.IsComplete() {
    let input = self.prefix.Bytes().Slice(self.offset, self.prefix.Len() - self.offset)
      .get_if<NetBytes>() as NetBytes;
    let decoded = self.decoder.Push(input, output);
    if decoded.IsErr() {
      return HttpServerError{kind: HttpServerErrorKind.Protocol, http: decoded.get_if<HttpError>()};
    }

    let step = decoded.get_if<HttpBodyProgress>() as HttpBodyProgress;
    self.offset += step.consumed;
    if step.produced != 0ip || step.state == HttpBodyState.Complete {
      return step.produced;
    }

    if self.offset == self.prefix.Len() {
      let received = self.FillPrefix();
      if received.IsErr() {
        return received.get_if<HttpServerError>() as HttpServerError;
      }

      if (received.get_if<intptr>() as intptr) == 0ip {
        let ended = self.decoder.EndInput();
        if ended.IsErr() {
          return HttpServerError{kind: HttpServerErrorKind.Protocol, http: ended.get_if<HttpError>()};
        }
      }
    }
  }

  return 0ip;
}

pub method(HttpServerExchange) RequestTrailerCount() -> Result<int32, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  let result = (cell as arc<HttpServerState>).decoder.TrailerCount();
  if result.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: result.get_if<HttpError>()};
  }

  return result.get_if<int32>() as int32;
}

pub method(HttpServerExchange) RequestTrailerAt(index: int32) -> Result<HttpField, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  let result = (cell as arc<HttpServerState>).decoder.TrailerAt(index);
  if result.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: result.get_if<HttpError>()};
  }

  return result.get_if<HttpField>() as HttpField;
}

pub method(HttpServerExchange) Upgrade(limits: ref WebSocketLimits) -> Result<WebSocket, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  var state = cell as arc<HttpServerState>;
  if state.responding {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  let prefix = state.prefix.Slice(state.offset, state.prefix.Len() - state.offset).get_if<NetBuffer>() as NetBuffer;
  var opened = WebSocket.AcceptTcp(state.connection, state.head, prefix, limits, state.options);
  self.cell = nil;
  if opened.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Upgrade, websocket: opened.get_if<WebSocketError>()};
  }

  return move(opened.get_if<WebSocket>() as WebSocket);
}
