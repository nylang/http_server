// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

part of HttpServerConnection;

pub method(HttpServerExchange) StartResponse(
  status: int32, reason: ref string, fields: ref <HttpField>[]
) -> Result<Unit, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  var state = cell as arc<HttpServerState>;
  if state.responding {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  let prepared = state.PrepareResponse(status, reason, fields);
  if prepared.IsErr() {
    return prepared.get_if<HttpServerError>() as HttpServerError;
  }

  let wire = prepared.get_if<NetBuffer>() as NetBuffer;
  let written = state.Send(wire.Bytes());
  if written.IsErr() {
    self.Close();
    return written;
  }

  state.responding = true;
  return UnitValue();
}

method(HttpServerState) PrepareResponse(
  status: int32, reason: ref string, fields: ref <HttpField>[]
) -> Result<NetBuffer, HttpServerError> {
  if status < 200 || status > 599 || fields.length > 99 {
    return HttpServerError{kind: HttpServerErrorKind.InvalidArgument};
  }

  let plan = self.head.BodyPlan().get_if<HttpBodyPlan>() as HttpBodyPlan;
  var framed = self.head.Method() == "HEAD" || status == 204 || status == 304;
  var i: int32 = 0;
  while i < fields.length {
    let field = fields[i];
    if field.name.EqualAsciiIgnoreCase("Connection") || field.name.EqualAsciiIgnoreCase("Upgrade") {
      return HttpServerError{kind: HttpServerErrorKind.InvalidArgument};
    }
    framed = framed || field.name.EqualAsciiIgnoreCase("Content-Length") ||
      field.name.EqualAsciiIgnoreCase("Transfer-Encoding");
    i += 1;
  }
  let can_reuse = framed && self.persistent && !self.close_after_response &&
    !plan.close_connection && self.decoder.IsComplete();
  var outgoing = new <HttpField>[fields.length + (can_reuse ? 0 : 1)];
  i = 0;
  while i < fields.length {
    outgoing[i] = fields[i];
    i += 1;
  }
  if !can_reuse {
    outgoing[i] = HttpField{name: "Connection", value: "close"};
  }

  let method_name = self.head.Method();
  let response = HttpHead.EncodeResponse(status, reason, outgoing, method_name);
  if response.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: response.get_if<HttpError>()};
  }

  let wire = response.get_if<NetBuffer>() as NetBuffer;
  var made = HttpHeadParser.NewResponse(method_name, HttpHeadLimits{});
  if made.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: made.get_if<HttpError>()};
  }

  var parser = move(made.get_if<HttpHeadParser>() as HttpHeadParser);
  let pushed = parser.Push(wire.Bytes());
  if pushed.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: pushed.get_if<HttpError>()};
  }

  let parsed = parser.Head();
  if parsed.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: parsed.get_if<HttpError>()};
  }

  let response_head = parsed.get_if<HttpHead>() as HttpHead;
  let response_plan = response_head.BodyPlan().get_if<HttpBodyPlan>() as HttpBodyPlan;
  if self.require_framed_response && response_plan.kind == HttpBodyKind.UntilEof {
    return HttpServerError{kind: HttpServerErrorKind.InvalidArgument};
  }

  var writer = HttpBodyWriter.New(response_head, self.limits.response_body);
  if writer.IsErr() {
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: writer.get_if<HttpError>()};
  }

  self.writer = move(writer.get_if<HttpBodyWriter>() as HttpBodyWriter);
  self.close_after_response = !can_reuse || response_plan.close_connection || response_plan.kind == HttpBodyKind.UntilEof;
  return wire;
}

pub method(HttpServerExchange) WriteBody(input: ref NetBytes) -> Result<Unit, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  var state = cell as arc<HttpServerState>;
  if !state.responding || state.response_finished {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  let written = state.StreamBody(input, false);
  if written.IsErr() {
    self.Close();
  }

  return written;
}

pub method(HttpServerExchange) FinishResponse() -> Result<Unit, HttpServerError> {
  let trailers: <HttpField>[0] = <HttpField>[0]{};
  return self.FinishResponseWithTrailers(trailers);
}

pub method(HttpServerExchange) FinishResponseWithTrailers(
  trailers: ref <HttpField>[]
) -> Result<Unit, HttpServerError> {
  let cell = self.cell;
  if cell == nil {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  var state = cell as arc<HttpServerState>;
  if !state.responding || state.response_finished {
    return HttpServerError{kind: HttpServerErrorKind.InvalidState};
  }

  let finished = state.writer.Finish(trailers);
  if finished.IsErr() {
    self.Close();
    return HttpServerError{kind: HttpServerErrorKind.Protocol, http: finished.get_if<HttpError>()};
  }

  let written = state.StreamBody(NetBytes{}, true);
  if state.close_after_response || written.IsErr() {
    self.Close();
  } else {
    state.response_finished = true;
  }
  return written;
}

method(HttpServerState) StreamBody(input: ref NetBytes, finishing: bool) -> Result<Unit, HttpServerError> {
  let control = self.Control();
  if control.IsErr() {
    return control;
  }

  var buffer: <uint8>[8192] = <uint8>[8192]{};
  let output = NetMutableBytes.FromRaw(&mut buffer[0], 8192ip).get_if<NetMutableBytes>() as NetMutableBytes;
  var offset: intptr = 0;
  while offset < input.Len() || (finishing && !self.writer.IsComplete()) {
    let rest = input.Slice(offset, input.Len() - offset).get_if<NetBytes>() as NetBytes;
    let result = self.writer.Push(rest, output);
    if result.IsErr() {
      return HttpServerError{kind: HttpServerErrorKind.Protocol, http: result.get_if<HttpError>()};
    }

    let step = result.get_if<HttpBodyProgress>() as HttpBodyProgress;
    let wire = output.AsReadOnly().Slice(0ip, step.produced).get_if<NetBytes>() as NetBytes;
    let written = self.Send(wire);
    if written.IsErr() {
      return written;
    }

    if step.consumed == 0ip && step.produced == 0ip && !self.writer.IsComplete() {
      return HttpServerError{kind: HttpServerErrorKind.InvalidState};
    }
    offset += step.consumed;
  }

  return UnitValue();
}
