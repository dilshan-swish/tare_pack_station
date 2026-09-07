import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/connection_issue.dart';
import '../data/headoffice_api.dart';
import 'settings_controller.dart';

/// The active head-office client, rebuilt when the connection settings change.
/// Null when the device hasn't been connected yet.
final headOfficeApiProvider = Provider<HeadOfficeApi?>((ref) {
  final s = ref.watch(settingsProvider.select((x) => x.headOffice));
  if (!s.isConnected) return null;
  final api = HeadOfficeApi(s);
  ref.onDispose(api.dispose);
  return api;
});

enum HeadOfficeStatus { notConfigured, online, offline }

/// The specific reason behind the current [HeadOfficeStatus], when offline —
/// e.g. "No internet, or the API address is wrong" vs. "Invalid or revoked
/// scale key". Null while online/not configured, or before the first ping.
/// The same classification is also reported to head office's device-event
/// log (see [HeadOfficeApi]), so this is what the portal shows too.
final headOfficeIssueProvider =
    NotifierProvider<HeadOfficeIssueNotifier, ConnectionIssue?>(
        HeadOfficeIssueNotifier.new);

class HeadOfficeIssueNotifier extends Notifier<ConnectionIssue?> {
  @override
  ConnectionIssue? build() => null;

  void set(ConnectionIssue? issue) => state = issue;
}

/// Sends a heartbeat every minute so the portal shows this scale online. Watch
/// this provider somewhere always-mounted (the queue screen) to keep it live.
final headOfficeHeartbeatProvider =
    NotifierProvider<HeadOfficeHeartbeat, HeadOfficeStatus>(
        HeadOfficeHeartbeat.new);

class HeadOfficeHeartbeat extends Notifier<HeadOfficeStatus> {
  Timer? _timer;

  @override
  HeadOfficeStatus build() {
    final api = ref.watch(headOfficeApiProvider);
    _timer?.cancel();
    ref.onDispose(() => _timer?.cancel());

    if (api == null) return HeadOfficeStatus.notConfigured;

    // Ping now, then every minute.
    _ping();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _ping());
    return HeadOfficeStatus.offline; // until the first ping lands
  }

  Future<void> _ping() async {
    final api = ref.read(headOfficeApiProvider);
    if (api == null) return;
    final ok = await api.heartbeat();
    state = ok ? HeadOfficeStatus.online : HeadOfficeStatus.offline;
    ref.read(headOfficeIssueProvider.notifier).set(api.lastIssue);
  }

  /// Manual ping used by the "Test connection" button.
  Future<bool> testNow() async {
    final api = ref.read(headOfficeApiProvider);
    if (api == null) return false;
    final ok = await api.heartbeat();
    state = ok ? HeadOfficeStatus.online : HeadOfficeStatus.offline;
    ref.read(headOfficeIssueProvider.notifier).set(api.lastIssue);
    return ok;
  }
}
