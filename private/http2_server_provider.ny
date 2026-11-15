// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

/** @brief Owns the optional provider shared library and its native HTTP/2 session. */
module Http2ServerProvider;
import "stdlib:stdlib.ny";
import "http:http2.ny";

pub struct Http2ServerNativeField {
  name: *const uint8;
  value: *const uint8;
  name_size: int32;
  value_size: int32;
}

typedef OpenHttp2ServerProvider = cfn<(int32, *mut Http2ServerProviderApi) -> int32>;

pub struct Http2ServerProviderApi {
  create: cfn<(int32, int32, int32) -> *mut int8>;
  destroy: cfn<(*mut int8) -> void>;
  output: cfn<(*mut int8, *mut *const uint8) -> intptr>;
  input: cfn<(*mut int8, *const uint8, intptr) -> intptr>;
  state: cfn<(*mut int8) -> int32>;
  pending: cfn<(*mut int8) -> int32>;
  next: cfn<(*mut int8, *mut *const uint8, *mut int32, *mut int32) -> int32>;
  field: cfn<(*mut int8, int32, int32, *mut Http2ServerNativeField) -> int32>;
  respond: cfn<(*mut int8, int32, int32, *const Http2ServerNativeField, int32, *const uint8, int32) -> int32>;
  reset: cfn<(*mut int8, int32) -> int32>;
}

pub struct Http2ServerProvider {
  library: DynamicLibrary;
  api: Http2ServerProviderApi;
  handle: *mut int8;
}

pub method(Http2ServerProvider) operator move() -> Http2ServerProvider {
  let handle = self.handle;
  self.handle = nil;

  return Http2ServerProvider{library: move(self.library), api: self.api, handle: handle};
}

pub method(Http2ServerProvider) operator drop() -> void {
  if self.handle != nil {
    self.api.destroy(self.handle);
    self.handle = nil;
  }
}

func symbol_address(value: *mut void) -> uintptr {
  return value as uintptr;
}

func missing_symbol(_error: FfiError) -> uintptr {
  return 0up;
}

pub static method(Http2ServerProvider) Open(
  path: ref string, limits: ref Http2Limits, secure: bool
) -> Result<Http2ServerProvider, Http2Error> {
  var loaded = DynamicLibrary.Load(path);
  if loaded.IsErr() {
    return Http2Error{kind: Http2ErrorKind.Provider, provider: loaded.get_if<FfiError>()};
  }

  var library = move(loaded.get_if<DynamicLibrary>() as DynamicLibrary);
  let entry = library.GetSymbol("nyra_http2_server_provider");
  let address = entry.visit(symbol_address, missing_symbol);
  if address == 0up {
    return Http2Error{kind: Http2ErrorKind.Provider, provider: entry.get_if<FfiError>()};
  }

  var api = Http2ServerProviderApi{};
  unsafe {
    let open = address as OpenHttp2ServerProvider;
    if open(1, &mut api) != 1 {
      return Http2Error{kind: Http2ErrorKind.Provider, provider: FfiError.NotSupported};
    }
  }

  let streams = limits.max_streams == 0 ? 8 : limits.max_streams;
  let bytes = limits.max_body_bytes == 0 ? 8388608 : limits.max_body_bytes;
  let handle = api.create(streams, bytes, secure ? 1 : 0);
  if handle == nil {
    return Http2Error{kind: Http2ErrorKind.ResourceExhausted};
  }

  return Http2ServerProvider{library: move(library), api: api, handle: handle};
}
