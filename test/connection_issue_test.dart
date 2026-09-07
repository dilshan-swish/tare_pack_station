import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tare_pack_station/data/connection_issue.dart';

void main() {
  group('classifyConnectionFailure', () {
    test('a TimeoutException classifies as timeout', () {
      expect(classifyConnectionFailure(error: TimeoutException('too slow')),
          ConnectionIssue.timeout);
    });

    test('any other thrown error (DNS/socket/etc.) classifies as no internet', () {
      expect(classifyConnectionFailure(error: Exception('Failed host lookup')),
          ConnectionIssue.noInternet);
    });

    test('a 401 status classifies as unauthorized', () {
      expect(classifyConnectionFailure(statusCode: 401), ConnectionIssue.unauthorized);
    });

    test('a non-200, non-401 status classifies as server error', () {
      expect(classifyConnectionFailure(statusCode: 500), ConnectionIssue.serverError);
      expect(classifyConnectionFailure(statusCode: 410), ConnectionIssue.serverError);
    });

    test('neither an error nor a bad status (reached the server, bad body) '
        'classifies as malformed response', () {
      expect(classifyConnectionFailure(), ConnectionIssue.malformedResponse);
      expect(classifyConnectionFailure(statusCode: 200), ConnectionIssue.malformedResponse);
    });
  });

  test('every ConnectionIssue has a distinct, non-empty code and label', () {
    final codes = <String>{};
    for (final issue in ConnectionIssue.values) {
      expect(issue.code, isNotEmpty);
      expect(issue.label, isNotEmpty);
      expect(codes.add(issue.code), isTrue, reason: 'duplicate code for $issue');
    }
  });
}
