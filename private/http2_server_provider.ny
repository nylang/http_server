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
typedef OpenHttp2StreamingProvider = cfn<(int32, *mut Http2StreamingProviderApi) -> int32>;
typedef OpenHttp2DuplexProvider = cfn<(int32, *mut Http2DuplexProviderApi) -> int32>;

pub typedef Http2StreamHeadCallback = cfn<(*mut void, *mut int8, int32, int32) -> int32>;
pub typedef Http2StreamDataCallback = cfn<(*mut void, int32, *const uint8, int32) -> int32>;
pub typedef Http2StreamClosedCallback = cfn<(*mut void, int32, uint32) -> void>;
pub typedef Http2StreamProduceCallback = cfn<(*mut void, int32, *mut uint8, int32) -> int32>;
pub typedef Http2StreamRespond = cfn<(*mut int8, int32, int32, *const Http2ServerNativeField, int32, int32) -> int32>;

/** @brief POD table of callbacks invoked synchronously by the streaming provider. */
pub struct Http2StreamCallbacks {
  head: Http2StreamHeadCallback;
  data: Http2StreamDataCallback;
  end: Http2StreamHeadCallback;
  closed: Http2StreamClosedCallback;
  produce: Http2StreamProduceCallback;
}

pub typedef Http2DuplexDataCallback = cfn<(*mut void, *mut int8, int32, *const uint8, int32) -> int32>;
pub typedef Http2DuplexProduceCallback = cfn<(*mut void, int32, *mut uint8, int32, *mut int32) -> int32>;

/** @brief Native duplex callbacks borrowing the session and supplied byte views. */
pub struct Http2DuplexCallbacks {
  head: Http2StreamHeadCallback;
  data: Http2DuplexDataCallback;
  end: Http2StreamHeadCallback;
  closed: Http2StreamClosedCallback;
  produce: Http2DuplexProduceCallback;
}

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

/** @brief Versioned streaming symbol. The original provider table remains callable. */
pub struct Http2StreamingProviderApi {
  core: Http2ServerProviderApi;
  create: cfn<(int32, int32, int32, *mut void, *const Http2StreamCallbacks) -> *mut int8>;
  respond: Http2StreamRespond;
}

/** @brief Versioned native duplex entry point. */
pub struct Http2DuplexProviderApi {
  core: Http2ServerProviderApi;
  create: cfn<(int32, int32, int32, *mut void, *const Http2DuplexCallbacks) -> *mut int8>;
  respond: Http2StreamRespond;
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
  self.Close();
}

/** @brief Release session state while any registered callback context is still live. */
pub method(Http2ServerProvider) Close() -> void {
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

  let handle = api.create(Http2ServerProvider.StreamCount(limits), Http2ServerProvider.BodyLimit(limits), secure ? 1 : 0);
  if handle == nil {
    return Http2Error{kind: Http2ErrorKind.ResourceExhausted};
  }

  return Http2ServerProvider{library: move(library), api: api, handle: handle};
}

/** @brief Resolve the streaming entry point and set up its borrowed callback context. */
pub static method(Http2ServerProvider) OpenStreaming(
  path: ref string, limits: ref Http2Limits, secure: bool,
  callbacks: ref Http2StreamCallbacks, context: *mut void, api: ref mut Http2StreamingProviderApi
) -> Result<Http2ServerProvider, Http2Error> {
  var loaded = DynamicLibrary.Load(path);
  if loaded.IsErr() {
    return Http2Error{kind: Http2ErrorKind.Provider, provider: loaded.get_if<FfiError>()};
  }

  var library = move(loaded.get_if<DynamicLibrary>() as DynamicLibrary);
  let entry = library.GetSymbol("nyra_http2_server_streaming_provider");
  let address = entry.visit(symbol_address, missing_symbol);
  if address == 0up {
    return Http2Error{kind: Http2ErrorKind.Provider, provider: entry.get_if<FfiError>()};
  }

  unsafe {
    let open = address as OpenHttp2StreamingProvider;
    if open(1, &mut api) != 1 {
      return Http2Error{kind: Http2ErrorKind.Provider, provider: FfiError.NotSupported};
    }
  }

  let handle = api.create(
    Http2ServerProvider.StreamCount(limits), Http2ServerProvider.BodyLimit(limits), secure ? 1 : 0, context, &callbacks
  );
  if handle == nil {
    return Http2Error{kind: Http2ErrorKind.ResourceExhausted};
  }

  return Http2ServerProvider{library: move(library), api: api.core, handle: handle};
}

/** @brief Resolve the duplex entry point and register the borrowed callback context. */
pub static method(Http2ServerProvider) OpenDuplex(
  path: ref string, limits: ref Http2Limits, secure: bool,
  callbacks: ref Http2DuplexCallbacks, context: *mut void, api: ref mut Http2DuplexProviderApi
) -> Result<Http2ServerProvider, Http2Error> {
  var loaded = DynamicLibrary.Load(path);
  if loaded.IsErr() {
    return Http2Error{kind: Http2ErrorKind.Provider, provider: loaded.get_if<FfiError>()};
  }

  var library = move(loaded.get_if<DynamicLibrary>() as DynamicLibrary);
  let entry = library.GetSymbol("nyra_http2_server_duplex_provider");
  let address = entry.visit(symbol_address, missing_symbol);
  if address == 0up {
    return Http2Error{kind: Http2ErrorKind.Provider, provider: entry.get_if<FfiError>()};
  }

  unsafe {
    let open = address as OpenHttp2DuplexProvider;
    if open(1, &mut api) != 1 {
      return Http2Error{kind: Http2ErrorKind.Provider, provider: FfiError.NotSupported};
    }
  }

  let handle = api.create(
    Http2ServerProvider.StreamCount(limits), Http2ServerProvider.BodyLimit(limits), secure ? 1 : 0, context, &callbacks
  );
  if handle == nil {
    return Http2Error{kind: Http2ErrorKind.ResourceExhausted};
  }

  return Http2ServerProvider{library: move(library), api: api.core, handle: handle};
}

static method(Http2ServerProvider) StreamCount(limits: ref Http2Limits) -> int32 {
  return limits.max_streams == 0 ? 8 : limits.max_streams;
}

static method(Http2ServerProvider) BodyLimit(limits: ref Http2Limits) -> int32 {
  return limits.max_body_bytes == 0 ? 8388608 : limits.max_body_bytes;
}
