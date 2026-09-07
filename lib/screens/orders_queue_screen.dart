import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/order.dart';
import '../models/order_status.dart';
import '../state/headoffice_controller.dart';
import '../state/headoffice_menu_controller.dart';
import '../state/menu_index_provider.dart';
import '../state/order_math.dart';
import '../state/orders_controller.dart';
import '../state/weigh_event_queue_controller.dart';
import '../state/weight_model_controller.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/kitchen_stage_pill.dart';
import '../widgets/neo_card.dart';
import '../widgets/pill_button.dart';
import '../widgets/scale_pill.dart';
import '../widgets/themed_scrollbar.dart';
import 'order_detail_screen.dart';
import 'settings_screen.dart';

/// The pack-station landing page — a clean, single scrollable window grouping
/// orders by stage (To Be Weighed · Ready for Pickup), with a compact control
/// row (no fixed header) and a floating live-weight pill. There's no separate
/// "Out for Delivery" stage: Foodics doesn't expose a reliable driver-pickup
/// signal for this integration (delivery is fulfilled by third-party
/// aggregators whose rider tracking never syncs back), so every weighed order
/// — whether it ends up picked up or delivered — lives in one section.
class OrdersQueueScreen extends ConsumerStatefulWidget {
  const OrdersQueueScreen({super.key});

  @override
  ConsumerState<OrdersQueueScreen> createState() => _OrdersQueueScreenState();
}

class _OrdersQueueScreenState extends ConsumerState<OrdersQueueScreen> {
  static const _syncEvery = Duration(seconds: 10);

  Timer? _autoSync;
  Timer? _ticker;
  DateTime? _lastSynced;
  bool _syncing = false;
  bool _syncingMenu = false;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _autoSync = Timer.periodic(_syncEvery, (_) => _sync());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _autoSync?.cancel();
    _ticker?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _sync() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    await ref.read(ordersProvider.notifier).silentRefresh();
    if (!mounted) return;
    setState(() => _syncing = false);
  }

  /// Pulls the latest published menu weights from head office right now,
  /// same action as "Sync Menu" in Settings — surfaced here too since staff
  /// mostly live on this screen and shouldn't need to dig into Settings for
  /// something this common right after a portal publish.
  Future<void> _syncMenu() async {
    if (_syncingMenu) return;
    setState(() => _syncingMenu = true);
    await ref.read(headOfficeMenuProvider.notifier).refreshNow();
    if (!mounted) return;
    setState(() => _syncingMenu = false);
  }

  // "synced " prefix dropped deliberately — the checkmark icon on this chip
  // already says what it is, and every character here counts toward whether
  // the whole strip fits on one line at realistic tablet widths.
  String _agoLabel() {
    final t = _lastSynced;
    if (t == null) return 'syncing…';
    final s = DateTime.now().difference(t).inSeconds;
    if (s <= 1) return 'just now';
    if (s < 60) return '${s}s ago';
    return '${s ~/ 60}m ago';
  }

  void _open(Order order) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OrderDetailScreen(orderId: order.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ordersAsync = ref.watch(ordersProvider);
    // Watched here so the head-office heartbeat, menu sync, and optional ML
    // model sync all run while the app is open (a Notifier only stays alive
    // while something watches it).
    final hoStatus = ref.watch(headOfficeHeartbeatProvider);
    final menu = ref.watch(headOfficeMenuProvider);
    ref.watch(weightModelProvider);
    final queuedWeighEvents = ref.watch(weighEventQueueProvider);

    ref.listen(ordersProvider, (prev, next) {
      if (next.hasValue && !next.isLoading) _lastSynced = DateTime.now();
    });

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pad = constraints.maxWidth < 500 ? 16.0 : 28.0;

            final orders = ordersAsync.value ?? const <Order>[];
            final toWeigh = [
              for (final o in orders)
                if (o.status != OrderStatus.dispatched) o,
            ];
            final done = [
              for (final o in orders)
                if (o.status == OrderStatus.dispatched) o,
            ];
            final correct = done.where((o) => o.overrideReason == null).length;
            final accuracy =
                done.isEmpty ? 100 : ((correct / done.length) * 100).round();

            final controls = _ControlStrip(
              statusLabel: _agoLabel(),
              syncing: _syncing,
              syncingMenu: _syncingMenu,
              streak: correct,
              accuracy: accuracy,
              hoStatus: hoStatus,
              menu: menu,
              queuedWeighEvents: queuedWeighEvents,
              onSync: _sync,
              onSyncMenu: _syncMenu,
              onSettings: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
              ),
            );

            return Stack(
              children: [
                ThemedScrollbar(
                  controller: _scroll,
                  child: CustomScrollView(
                    controller: _scroll,
                    slivers: [
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(pad, pad, pad, 6),
                        sliver: SliverToBoxAdapter(child: controls),
                      ),
                      ...ordersAsync.when(
                        loading: () => const <Widget>[
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _QueueLoading(),
                          ),
                        ],
                        error: (err, _) => <Widget>[
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _QueueError(
                              message: '$err',
                              onRetry: () =>
                                  ref.read(ordersProvider.notifier).refresh(),
                            ),
                          ),
                        ],
                        data: (_) => _sections(pad, toWeigh, done),
                      ),
                      const SliverToBoxAdapter(child: SizedBox(height: 96)),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 18,
                  child: Center(
                    child: SafeArea(top: false, child: const ScalePill()),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<Widget> _sections(double pad, List<Order> toWeigh, List<Order> done) {
    return [
      _sectionHeader(pad, 'To Be Weighed', count: toWeigh.length),
      if (toWeigh.isEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 8),
          sliver: const SliverToBoxAdapter(child: _AllWeighedEmpty()),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 6, pad, 8),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 360,
              mainAxisExtent: 140,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) =>
                  _ToWeighCard(order: toWeigh[i], onTap: () => _open(toWeigh[i])),
              childCount: toWeigh.length,
            ),
          ),
        ),
      _sectionHeader(pad, 'Ready for Pickup', count: done.length, topGap: 20),
      if (done.isEmpty)
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 4, pad, 8),
          sliver: const SliverToBoxAdapter(
            child: _SectionNote('Weighed orders will appear here.'),
          ),
        )
      else
        SliverPadding(
          padding: EdgeInsets.fromLTRB(pad, 6, pad, 8),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 320,
              mainAxisExtent: 82,
              crossAxisSpacing: 16,
              mainAxisSpacing: 16,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, i) =>
                  _ReadyCard(order: done[i], onTap: () => _open(done[i])),
              childCount: done.length,
            ),
          ),
        ),
    ];
  }

  Widget _sectionHeader(double pad, String title,
      {int? count, double topGap = 6}) {
    return SliverPadding(
      padding: EdgeInsets.fromLTRB(pad, topGap, pad, 0),
      sliver: SliverToBoxAdapter(
        child: Row(
          children: [
            Text(title, style: AppTextStyles.display(size: 17)),
            if (count != null && count > 0) ...[
              const SizedBox(width: 10),
              _CountBadge(count: count),
            ],
          ],
        ),
      ),
    );
  }

}

// ---------------------------------------------------------------------------
// Control row (scrolls with the list — no fixed header).
// ---------------------------------------------------------------------------

class _ControlStrip extends StatelessWidget {
  final String statusLabel;
  final bool syncing;
  final bool syncingMenu;
  final int streak;
  final int accuracy;
  final HeadOfficeStatus hoStatus;
  final HeadOfficeMenuState menu;
  final int queuedWeighEvents;
  final VoidCallback onSync;
  final VoidCallback onSyncMenu;
  final VoidCallback onSettings;

  const _ControlStrip({
    required this.statusLabel,
    required this.syncing,
    required this.syncingMenu,
    required this.streak,
    required this.accuracy,
    required this.hoStatus,
    required this.menu,
    required this.queuedWeighEvents,
    required this.onSync,
    required this.onSyncMenu,
    required this.onSettings,
  });

  /// "BBT · Yard Branch" — prefers Foodics' own localized branch name over
  /// the raw code, never a raw Foodics id, and hidden entirely (returns null)
  /// until this device's own brand/branch is actually known.
  String? _branchLabel() {
    if (menu.brandCode.isEmpty) return null;
    final display = menu.branchDisplayName;
    final branch = (display != null && display.isNotEmpty)
        ? display
        : (menu.foodicsBranchId != null ? 'this branch' : null);
    return branch != null ? '${menu.brandCode} · $branch' : menu.brandCode;
  }

  String _kuwaitTimeLabel() {
    // Kuwait is a fixed UTC+3 with no daylight saving — pure local arithmetic
    // on the device's own clock, so this stays correct with zero network
    // dependency (no time server, no internet required).
    final kwt = DateTime.now().toUtc().add(const Duration(hours: 3));
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(kwt.hour)}:${two(kwt.minute)} KWT';
  }

  @override
  Widget build(BuildContext context) {
    final connected = hoStatus != HeadOfficeStatus.notConfigured;
    final branchLabel = connected ? _branchLabel() : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _Chip(icon: Icons.local_fire_department, label: '$streak', tint: AppColors.amber),
              _Chip(icon: Icons.verified, label: '$accuracy%', tint: AppColors.green),
              if (connected)
                _Chip(
                  icon: hoStatus == HeadOfficeStatus.online
                      ? Icons.cloud_done
                      : Icons.cloud_off,
                  label: 'HQ',
                  tint: hoStatus == HeadOfficeStatus.online
                      ? AppColors.green
                      : AppColors.coral,
                ),
              // Weighs recorded while HQ (or the network) was unreachable —
              // held locally, retried automatically, never lost. Only shown
              // once there's actually something waiting, so this chip stays
              // invisible on every normal, fully-connected day.
              if (queuedWeighEvents > 0)
                _Chip(
                  icon: Icons.cloud_upload,
                  label: '$queuedWeighEvents pending sync',
                  tint: AppColors.amber,
                ),
              // Doubles as "Sync now" — orders already auto-sync every 10s,
              // so a dedicated button was mostly redundant; tapping the
              // status itself covers the rare case someone wants it sooner.
              _Chip(
                icon: syncing ? Icons.sync : Icons.check_circle_outline,
                label: statusLabel,
                tint: AppColors.muted,
                onTap: syncing ? null : onSync,
              ),
              _Chip(icon: Icons.schedule, label: _kuwaitTimeLabel(), tint: AppColors.ink),
              if (connected)
                NeoIconButton(
                  icon: Icons.restart_alt,
                  tooltip: syncingMenu ? 'Syncing menu…' : 'Sync Menu',
                  foreground: syncingMenu ? AppColors.muted : AppColors.ink,
                  onPressed: syncingMenu ? null : onSyncMenu,
                ),
              if (branchLabel != null)
                _Chip(icon: Icons.storefront, label: branchLabel, tint: AppColors.green),
            ],
          ),
        ),
        const SizedBox(width: 10),
        NeoIconButton(
          icon: Icons.settings,
          tooltip: 'Settings',
          onPressed: onSettings,
        ),
      ],
    );
  }
}

/// A small light chip: white surface, hairline border, tinted icon. Optionally
/// tappable (e.g. the "synced Xs ago" chip doubles as a manual sync trigger).
class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color tint;
  final VoidCallback? onTap;
  const _Chip({
    required this.icon,
    required this.label,
    required this.tint,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: AppColors.line, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: tint),
          const SizedBox(width: 6),
          Text(label,
              style: AppTextStyles.mono(
                  size: 12.5, weight: FontWeight.w700, color: AppColors.ink)),
        ],
      ),
    );
    if (onTap == null) return content;
    // The chip itself is visually compact, but tap targets must still be
    // >=44x44 for wet/gloved hands — the extra constraint pads the hit area
    // invisibly around the same small chip rather than growing it visually.
    //
    // `Center` WITHOUT widthFactor/heightFactor doesn't just shrink-wrap its
    // child — inside a Wrap it gets handed a bounded (if generous) width for
    // measurement, and a plain Center expands to fill any bounded width, not
    // only an unbounded one. That made this one chip measure as needing
    // nearly the entire row, forcing Wrap to give it a whole line to itself
    // with the real (small) content floating centered in all that invisible
    // space — exactly the "stray centered chip" bug this fixes. `widthFactor:
    // 1, heightFactor: 1` forces Center to hug the child's real size instead.
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(AppShapes.pillRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
          child: Center(widthFactor: 1, heightFactor: 1, child: content),
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  final int count;
  const _CountBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.amber.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
      ),
      child: Text('$count',
          style: AppTextStyles.mono(
              size: 12.5, weight: FontWeight.w700, color: AppColors.ink)),
    );
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

class _ToWeighCard extends ConsumerWidget {
  final Order order;
  final VoidCallback onTap;
  const _ToWeighCard({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Lets staff tell at a glance, before even opening the order, whether
    // every item/modifier on it has a configured weight yet — a card that
    // still has a gap can't be reliably weight-checked, so it's flagged the
    // same amber used everywhere else for "needs attention", rather than
    // staff discovering that only after tapping in.
    final menuIndex = ref.watch(menuIndexProvider);
    final combinationIndex = ref.watch(modifierCombinationIndexProvider);
    final fullyConfigured =
        !orderHasUnconfiguredWeight(order, menuIndex, combinationIndex: combinationIndex);
    return NeoCard(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      onTap: onTap,
      borderColor: fullyConfigured ? AppColors.green : AppColors.amber,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (order.receivedAt != null) ...[
                Icon(Icons.schedule, size: 13, color: AppColors.muted),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: order.receivedAt != null
                    ? Text('Received ${formatReceivedAt(order.receivedAt!)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.mono(
                            size: 11.5, color: AppColors.muted))
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 6),
              KitchenStagePill(stage: order.kitchenStage),
            ],
          ),
          Row(
            children: [
              if (order.displaySubtitle != null)
                Expanded(
                  child: Text(order.displaySubtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body(
                          size: 13,
                          weight: FontWeight.w600,
                          color: AppColors.muted)),
                )
              else
                const Spacer(),
              const SizedBox(width: 8),
              Icon(Icons.lunch_dining, size: 16, color: AppColors.muted),
              const SizedBox(width: 6),
              Text(
                '${order.itemCount} item${order.itemCount == 1 ? '' : 's'}',
                style: AppTextStyles.body(
                    size: 13, weight: FontWeight.w600, color: AppColors.muted),
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Text(order.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body(size: 20, weight: FontWeight.w700)),
              ),
              if (order.displayCheck != null) ...[
                const SizedBox(width: 8),
                Text(order.displayCheck!,
                    style: AppTextStyles.mono(size: 13, color: AppColors.muted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _ReadyCard extends StatelessWidget {
  final Order order;
  final VoidCallback onTap;
  const _ReadyCard({required this.order, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final flagged = order.overrideReason != null;
    return NeoCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      onTap: onTap,
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: (flagged ? AppColors.amber : AppColors.green)
                  .withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(flagged ? Icons.priority_high : Icons.check,
                size: 16,
                color: flagged ? AppColors.amber : AppColors.green),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(order.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body(size: 16, weight: FontWeight.w700)),
                if (order.displaySubtitle != null)
                  Text(order.displaySubtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.body(
                          size: 12, color: AppColors.muted)),
              ],
            ),
          ),
          if (order.displayCheck != null) ...[
            const SizedBox(width: 8),
            Text(order.displayCheck!,
                style: AppTextStyles.mono(size: 12.5, color: AppColors.muted)),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty / status states
// ---------------------------------------------------------------------------

class _AllWeighedEmpty extends StatelessWidget {
  const _AllWeighedEmpty();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30),
      child: Column(
        children: [
          Icon(Icons.inventory_2_outlined,
              size: 48, color: AppColors.muted.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text('All orders have been weighed',
              style: AppTextStyles.body(
                  size: 15.5, weight: FontWeight.w600, color: AppColors.muted)),
        ],
      ),
    );
  }
}

class _SectionNote extends StatelessWidget {
  final String text;
  const _SectionNote(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Text(text,
          style: AppTextStyles.body(size: 13.5, color: AppColors.muted)),
    );
  }
}

class _QueueLoading extends StatelessWidget {
  const _QueueLoading();
  @override
  Widget build(BuildContext context) {
    return const Center(child: CircularProgressIndicator(color: AppColors.green));
  }
}

class _QueueError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _QueueError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: NeoCard(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("Couldn't load orders", style: AppTextStyles.display(size: 20)),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(message,
                  textAlign: TextAlign.center,
                  style: AppTextStyles.body(size: 14, color: AppColors.muted)),
            ),
            const SizedBox(height: 18),
            PillButton(label: 'Retry', icon: Icons.refresh, onPressed: onRetry),
          ],
        ),
      ),
    );
  }
}
