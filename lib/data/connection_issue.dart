import 'dart:async';

/// Why a call to head office failed — classified so both the tablet (shown
/// locally, immediately) and the portal (reported, for when a scale can't be
/// physically checked) can tell staff something more useful than "offline".
enum ConnectionIssue {
  /// Reached head office and got back exactly what was expected.
  none,

  /// Couldn't even open a connection — DNS failure, unreachable host, no
  /// network at all. Usually: wrong API address, or the tablet has no
  /// internet/network connectivity.
  noInternet,

  /// Connected (or tried to) but it took too long. Usually a slow/overloaded
  /// network rather than a totally dead one.
  timeout,

  /// Head office responded, but said the scale key is invalid/revoked.
  unauthorized,

  /// Head office responded with a non-2xx status other than 401 — the API
  /// itself (or something in front of it) is having a problem.
  serverError,

  /// Got a 200, but the body wasn't shaped like our own API's response —
  /// e.g. a wrong address that happens to resolve to a different real server.
  malformedResponse,
}

extension ConnectionIssueX on ConnectionIssue {
  /// Short machine code sent to the backend's device-event log.
  String get code => switch (this) {
        ConnectionIssue.none => 'ok',
        ConnectionIssue.noInternet => 'no_internet',
        ConnectionIssue.timeout => 'timeout',
        ConnectionIssue.unauthorized => 'unauthorized',
        ConnectionIssue.serverError => 'server_error',
        ConnectionIssue.malformedResponse => 'malformed_response',
      };

  /// Human label shown locally on the tablet (Settings) and mappable by the
  /// portal from the same [code].
  String get label => switch (this) {
        ConnectionIssue.none => 'Connected',
        ConnectionIssue.noInternet => 'No internet, or the API address is wrong',
        ConnectionIssue.timeout => 'Timed out — slow or unreachable network',
        ConnectionIssue.unauthorized => 'Invalid or revoked scale key',
        ConnectionIssue.serverError => 'Head office responded with an error',
        ConnectionIssue.malformedResponse =>
          "Connected, but the response wasn't understood — check the API address",
      };
}

/// Classifies a failed head-office call from whichever of [error] (a thrown
/// exception) or [statusCode] (a received, non-2xx-or-malformed response) is
/// available. Pure/synchronous and never throws — safe to call from any
/// catch block.
ConnectionIssue classifyConnectionFailure({Object? error, int? statusCode}) {
  if (error != null) {
    if (error is TimeoutException) return ConnectionIssue.timeout;
    return ConnectionIssue.noInternet;
  }
  if (statusCode != null) {
    if (statusCode == 401) return ConnectionIssue.unauthorized;
    if (statusCode != 200) return ConnectionIssue.serverError;
  }
  // Reached the server with a 200, but the body didn't parse as expected.
  return ConnectionIssue.malformedResponse;
}
