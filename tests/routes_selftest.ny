// Copyright (c) 2026 tangxiangjiang
// SPDX-License-Identifier: MIT

import "stdlib:stdlib.ny";
import "ntest:ntest.ny";
import "http:http.ny";
import "net_core:net_core.ny";
import "http_server.ny";

@test
func test_http_routes_disambiguate_literals_and_patterns() {
  var routes = HttpRoutes.New();
  AssertTrue(routes.AddPattern("GET", "/files/{name}/{format}", 1));
  AssertTrue(routes.AddPattern("GET", "/files/{name}/raw", 2));
  AssertTrue(routes.Add("GET", "/files/default/raw", 3));
  AssertTrue(routes.AddPattern("POST", "/files/{file}/{type}", 4));
  AssertTrue(!routes.AddPattern("GET", "/files/{file}/{type}", 5));
  AssertTrue(!routes.AddPattern("GET", "/files/{name}/{name}", 5));
  AssertTrue(!routes.AddPattern("GET", "/files/{9name}", 5));
  AssertTrue(!routes.AddPattern("GET", "/files/prefix{name}", 5));
  AssertTrue(!routes.AddPattern("GET", "/files/{name}?q=1", 5));
  AssertTrue(!routes.AddPattern("GET", "/files/plain", 5));

  let literal = routes.MatchTarget("GET", "/files/default/raw?q=1");
  let captured = routes.MatchTarget("GET", "/files/a%2Fb/raw?q=1");
  let posted = routes.MatchTarget("POST", "/files/a%2Fb/raw");
  if AssertTrue(literal != nil && captured != nil && posted != nil) != 0 {
    return;
  }

  AssertEqI32((literal as HttpRouteMatch).id, 3);
  AssertEqI32((literal as HttpRouteMatch).params.Len(), 0);
  AssertEqI32((posted as HttpRouteMatch).id, 4);
  let match = captured as HttpRouteMatch;
  AssertEqI32(match.id, 1);
  AssertEqI32(match.params.Len(), 2);
  AssertEqString(match.params.Get(0).name, "name");
  AssertEqString(match.params.Get(0).value, "a%2Fb");
  AssertEqString(match.params.Get(1).name, "format");
  AssertEqString(match.params.Get(1).value, "raw");

  AssertTrue(routes.MatchTarget("GET", "/files//raw") == nil);
  AssertTrue(routes.MatchTarget("GET", "/files/a/raw/") == nil);
  AssertTrue(routes.MatchTarget("GET", "/files/a") == nil);
  AssertTrue(routes.MatchTarget("GET", "files/a/raw") == nil);
  AssertTrue(routes.MatchTarget("HEAD", "/files/a/raw") == nil);
}

@test
func test_http_routes_match_pattern_on_parsed_request() {
  var routes = HttpRoutes{};
  AssertTrue(routes.AddPattern("GET", "/files/{name}", 7));

  var opened = HttpHeadParser.NewRequest(HttpHeadLimits{});
  if AssertTrue(opened.IsOk()) != 0 {
    return;
  }

  var parser = move(opened.get_if<HttpHeadParser>() as HttpHeadParser);
  let wire = "GET /files/name?download=1 HTTP/1.1\r\nHost: localhost\r\n\r\n";
  let read = parser.Push(NetBytes.FromString(wire));
  if AssertTrue(read.IsOk() && parser.IsComplete()) != 0 {
    return;
  }

  let head = parser.Head();
  if AssertTrue(head.IsOk()) != 0 {
    return;
  }

  let route = routes.Match(head.get_if<HttpHead>() as HttpHead);
  AssertTrue(route != nil && (route as int32) == 7);
}
