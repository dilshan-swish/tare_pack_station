import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Raised when a Foodics API call fails in a way the UI should surface (auth
/// error, server error, network down). Carries a readable message.
class FoodicsException implements Exception {
  final String message;
  final int? statusCode;
  const FoodicsException(this.message, {this.statusCode});
  @override
  String toString() => 'FoodicsException($statusCode): $message';
}

/// Thin, resilient client for the Foodics v5 REST API.
///
/// Handles the things that bite real integrations:
///  • A browser-like `User-Agent` — Foodics sits behind Cloudflare, which
///    blocks default HTTP-client signatures with a 1010 error. This was
///    confirmed against the live API.
///  • Per-request timeout + a couple of backoff retries.
///  • Fail-fast on auth errors (401/403) and rate limits (429) with clear
///    messages; the queue can then show a retry-able state.
///  • Pagination for catalog endpoints.
class FoodicsApi {
  final String baseUrl;
  final String token;
  final http.Client _client;
  final Duration timeout;
  final int maxRetries;

  FoodicsApi({
    required this.baseUrl,
    required this.token,
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
    this.maxRetries = 2,
  }) : _client = client ?? http.Client();

  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0 Safari/537.36 TARE-PackStation';

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        'User-Agent': _userAgent,
      };

  String get _base =>
      baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;

  /// GETs [path] (already query-encoded) and returns the decoded JSON body.
  Future<Map<String, dynamic>> _getJson(String path) async {
    final uri = Uri.parse('$_base$path');
    Object? lastError;
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final res = await _client.get(uri, headers: _headers).timeout(timeout);
        switch (res.statusCode) {
          case 200:
            final decoded = jsonDecode(res.body);
            if (decoded is Map<String, dynamic>) return decoded;
            throw const FoodicsException('Unexpected response shape.');
          case 401:
          case 403:
            throw FoodicsException(
              'Foodics rejected the access token (${res.statusCode}). '
              'The token may be invalid, expired, or lack permissions.',
              statusCode: res.statusCode,
            );
          case 422:
            throw FoodicsException(
              'Foodics rejected the request (422) — check the branch/filters.',
              statusCode: 422,
            );
          case 429:
            lastError = const FoodicsException(
              'Foodics rate limit hit — easing off.',
              statusCode: 429,
            );
          default:
            lastError = FoodicsException(
              'Foodics returned HTTP ${res.statusCode}.',
              statusCode: res.statusCode,
            );
        }
      } on FoodicsException {
        rethrow;
      } on TimeoutException {
        lastError = const FoodicsException('The Foodics request timed out.');
      } catch (e) {
        lastError = FoodicsException('Could not reach Foodics: $e');
      }
      if (attempt < maxRetries) {
        await Future<void>.delayed(Duration(milliseconds: 500 * (attempt + 1)));
      }
    }
    throw (lastError is FoodicsException)
        ? lastError
        : FoodicsException('Could not reach Foodics: $lastError');
  }

  static List<Map<String, dynamic>> _dataList(Map<String, dynamic> body) {
    final data = body['data'];
    if (data is! List) return const [];
    return [for (final e in data) if (e is Map<String, dynamic>) e];
  }

  /// All branches for the brand.
  Future<List<Map<String, dynamic>>> listBranches() async {
    final body = await _getJson('/branches?per_page=50');
    return _dataList(body);
  }

  /// Orders relevant to a weight-check for a branch: status 1 (Pending), 2
  /// (Active — being prepared), or 4 (Closed — the till side is done, which is
  /// also when the food is packed and waiting to be weighed/dispatched;
  /// confirmed against the live API, a "Closed" order and "Ready To Deliver"
  /// happen together). Explicitly excludes 3 (Declined), 5 (Returned), 6
  /// (Joined), 7 (Void) and 8 (Draft) — the full status enum, confirmed
  /// against the Foodics console. `delivery_status` is deliberately not used
  /// anywhere: these branches don't populate it beyond "sent to kitchen"/
  /// "ready" in practice, so it isn't a reliable signal.
  ///
  /// Includes the product line → product relation, each line's selected
  /// modifier options resolved to their catalog name/id
  /// (`products.options.modifier_option` — without this, Foodics only returns
  /// an opaque per-order join id that can't be matched back to a weighed
  /// modifier), and the customer. Sorted newest first.
  ///
  /// Foodics requires the `filter[...]` brackets and comma lists to stay
  /// literal in the query — percent-encoding them yields HTTP 400 (confirmed
  /// against the live API). Only the branch id value is encoded.
  Future<List<Map<String, dynamic>>> listOpenOrders(String branchId) async {
    final b = Uri.encodeComponent(branchId);
    final query = 'filter[branch_id]=$b'
        '&filter[status]=1,2,4'
        '&include=products,products.product,products.options.modifier_option,customer'
        '&sort=-created_at'
        '&per_page=50';
    final body = await _getJson('/orders?$query');
    return _dataList(body);
  }

  /// All active products (the menu), paginated. Capped to avoid runaway loops.
  Future<List<Map<String, dynamic>>> listProducts({int maxPages = 30}) async {
    final all = <Map<String, dynamic>>[];
    for (var page = 1; page <= maxPages; page++) {
      final body = await _getJson('/products?per_page=50&page=$page&include=category');
      all.addAll(_dataList(body));
      final meta = body['meta'];
      final last = (meta is Map && meta['last_page'] is num)
          ? (meta['last_page'] as num).toInt()
          : page;
      if (page >= last) break;
    }
    return all;
  }

  void dispose() => _client.close();
}
