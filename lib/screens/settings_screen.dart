import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/discrepancy_providers.dart';
import '../data/connection_issue.dart';
import '../data/foodics_api.dart';
import '../data/settings_store.dart';
import '../models/foodics_brand.dart';
import '../models/foodics_settings.dart';
import '../models/headoffice_settings.dart';
import '../models/menu_item.dart';
import '../models/modifier.dart';
import '../models/serial_settings.dart';
import '../models/weight_source_type.dart';
import '../state/foodics_controller.dart';
import '../state/headoffice_controller.dart';
import '../state/headoffice_menu_controller.dart';
import '../state/settings_controller.dart';
import '../state/weight_model_controller.dart';
import '../state/weight_providers.dart';
import '../weight/serial_weight_source.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../theme/app_theme.dart';
import '../util/format.dart';
import '../widgets/neo_card.dart';
import '../widgets/pill_button.dart';
import '../widgets/themed_scrollbar.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  int _tab = 0; // 0 = General settings, 1 = Menu item weights
  final ScrollController _generalScroll = ScrollController();

  @override
  void dispose() {
    _generalScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final pad = constraints.maxWidth < 500 ? 16.0 : 28.0;
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Fixed, compact top (no overlay): a single back+title row
                    // plus the section tabs — kept deliberately short so it
                    // never eats into the content below on shorter screens.
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad, pad, pad, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              NeoIconButton(
                                icon: Icons.arrow_back,
                                tooltip: 'All orders',
                                onPressed: () => Navigator.of(context).pop(),
                              ),
                              const SizedBox(width: 14),
                              Text('Settings',
                                  style: AppTextStyles.display(
                                      size: 22, color: AppColors.heading)),
                            ],
                          ),
                          const SizedBox(height: 10),
                          _SectionTabs(
                            selected: _tab,
                            onSelect: (i) => setState(() => _tab = i),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: _tab == 0
                          ? _GeneralTab(
                              settings: settings,
                              controller: _generalScroll,
                              pad: pad,
                            )
                          : _MenuWeightsTab(pad: pad),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The two settings sections shown side by side; the selected one is underlined
/// (in amber) and its content is what shows below.
class _SectionTabs extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  const _SectionTabs({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _tab('General settings', 0),
          const SizedBox(width: 22),
          _tab('Menu item weights', 1),
        ],
      ),
    );
  }

  Widget _tab(String label, int index) {
    final sel = selected == index;
    return InkWell(
      onTap: () => onSelect(index),
      borderRadius: BorderRadius.circular(8),
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 8, 2, 8),
              child: Text(
                label,
                style: AppTextStyles.body(
                  size: 16,
                  weight: sel ? FontWeight.w700 : FontWeight.w600,
                  color: AppColors.heading.withValues(alpha: sel ? 1 : 0.6),
                ),
              ),
            ),
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: sel ? AppColors.amber : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// General settings tab — head office, weight source, serial, Foodics (live
/// orders) and AI model sections in one themed-scrollbar list.
class _GeneralTab extends StatelessWidget {
  final AppSettings settings;
  final ScrollController controller;
  final double pad;
  const _GeneralTab({
    required this.settings,
    required this.controller,
    required this.pad,
  });

  @override
  Widget build(BuildContext context) {
    return ThemedScrollbar(
      controller: controller,
      child: ListView(
        controller: controller,
        padding: EdgeInsets.fromLTRB(pad, 8, pad, pad),
        children: [
          _HeadOfficeSection(headOffice: settings.headOffice),
          const SizedBox(height: 20),
          _WeightSourceSection(settings: settings),
          const SizedBox(height: 20),
          if (settings.weightSourceType.isSerial) ...[
            _SerialSection(serial: settings.serial),
            const SizedBox(height: 20),
          ],
          _FoodicsSection(foodics: settings.foodics),
          const SizedBox(height: 20),
          const _WeightModelSection(),
          const SizedBox(height: 20),
          const _AiModelSection(),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------

class _HeadOfficeSection extends ConsumerStatefulWidget {
  final HeadOfficeSettings headOffice;
  const _HeadOfficeSection({required this.headOffice});

  @override
  ConsumerState<_HeadOfficeSection> createState() => _HeadOfficeSectionState();
}

class _HeadOfficeSectionState extends ConsumerState<_HeadOfficeSection> {
  late final TextEditingController _url =
      TextEditingController(text: widget.headOffice.baseUrl);
  late final TextEditingController _key =
      TextEditingController(text: widget.headOffice.deviceKey);
  bool _testing = false;
  bool? _ok;
  String? _msg;
  bool _syncingMenu = false;
  String? _syncMsg;

  @override
  void didUpdateWidget(_HeadOfficeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    // `late final` controllers only read widget.headOffice once, at
    // construction — if it's ever replaced from outside this widget (e.g. a
    // future remote-provisioning flow, or settings reloading) while this
    // section stays mounted, these fields would otherwise show stale values
    // forever. Only auto-resync when the field still matches what it was
    // last set to, so the user's own in-progress typing is never clobbered.
    if (widget.headOffice.baseUrl != oldWidget.headOffice.baseUrl &&
        _url.text == oldWidget.headOffice.baseUrl) {
      _url.text = widget.headOffice.baseUrl;
    }
    if (widget.headOffice.deviceKey != oldWidget.headOffice.deviceKey &&
        _key.text == oldWidget.headOffice.deviceKey) {
      _key.text = widget.headOffice.deviceKey;
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _saveAndTest() async {
    FocusScope.of(context).unfocus();
    final ho = HeadOfficeSettings(
      baseUrl: _url.text.trim(),
      deviceKey: _key.text.trim(),
    );
    ref.read(settingsProvider.notifier).setHeadOffice(ho);
    if (!ho.isConnected) {
      setState(() {
        _ok = null;
        _msg = 'Enter both the API address and the scale key.';
      });
      return;
    }
    setState(() {
      _testing = true;
      _msg = null;
      _ok = null;
    });
    final ok = await ref.read(headOfficeHeartbeatProvider.notifier).testNow();
    if (!mounted) return;
    setState(() {
      _testing = false;
      _ok = ok;
      _msg = ok
          ? 'Connected — this scale now shows online in the portal.'
          : 'Saved, but head office did not respond. Check the address, the key, and the network.';
    });
  }

  /// Pulls the latest published item/modifier weights from head office right
  /// now, instead of waiting for the periodic background refresh — this app
  /// never authors weights itself, it only ever reads/pulls them.
  Future<void> _syncMenu() async {
    setState(() {
      _syncingMenu = true;
      _syncMsg = null;
    });
    final before = ref.read(headOfficeMenuProvider).items.length;
    await ref.read(headOfficeMenuProvider.notifier).refreshNow();
    if (!mounted) return;
    final after = ref.read(headOfficeMenuProvider).items;
    setState(() {
      _syncingMenu = false;
      _syncMsg = after.isEmpty
          ? "Couldn't reach head office — still using the last-known weights."
          : 'Synced ${after.length} item${after.length == 1 ? '' : 's'}'
              '${after.length != before ? ' (was $before)' : ''}.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(headOfficeHeartbeatProvider);
    final issue = ref.watch(headOfficeIssueProvider);
    final menu = ref.watch(headOfficeMenuProvider);
    return _SectionCard(
      title: 'Head-office connection',
      subtitle:
          'Connect this smart scale to the branch it was registered to in the portal.',
      trailing: _statusChip(status),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field('API address', _url, 'http://10.0.0.5:5025'),
          const SizedBox(height: 14),
          _field('Scale key', _key, 'XXXX-XXXX', obscure: true),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              PillButton(
                label: _testing ? 'Testing…' : 'Save & test connection',
                icon: Icons.wifi_tethering,
                onPressed: _testing ? null : _saveAndTest,
              ),
              if (status != HeadOfficeStatus.notConfigured)
                PillButton(
                  label: _syncingMenu ? 'Syncing…' : 'Sync Menu',
                  icon: Icons.sync,
                  variant: PillButtonVariant.outline,
                  onPressed: _syncingMenu ? null : _syncMenu,
                ),
            ],
          ),
          if (status != HeadOfficeStatus.notConfigured) ...[
            const SizedBox(height: 10),
            Text(_menuStatusLabel(menu),
                style: AppTextStyles.body(size: 12.5, color: AppColors.muted)),
          ],
          // Shown the moment head office stops responding — the same
          // classification is reported to head office's own device log, so
          // this is exactly what the portal will show for this scale too.
          if (status == HeadOfficeStatus.offline &&
              issue != null &&
              issue != ConnectionIssue.none) ...[
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline, size: 15, color: AppColors.underText),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(issue.label,
                      style: AppTextStyles.body(
                          size: 12.5,
                          weight: FontWeight.w600,
                          color: AppColors.underText)),
                ),
              ],
            ),
          ],
          if (_syncMsg != null) ...[
            const SizedBox(height: 6),
            Text(_syncMsg!,
                style: AppTextStyles.body(
                    size: 12.5, weight: FontWeight.w600, color: AppColors.ink)),
          ],
          if (_msg != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _ok == true ? AppColors.okGreenBg : AppColors.underBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      _ok == true ? AppColors.okGreenText : AppColors.underText,
                  width: 2,
                ),
              ),
              child: Text(
                _msg!,
                style: AppTextStyles.body(
                  size: 13.5,
                  weight: FontWeight.w600,
                  color:
                      _ok == true ? AppColors.okGreenText : AppColors.underText,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _menuStatusLabel(HeadOfficeMenuState menu) {
    if (!menu.hasData) return 'Menu: not synced yet.';
    final count = menu.items.length;
    final synced = menu.syncedAt;
    if (synced == null) {
      return 'Menu: $count item${count == 1 ? '' : 's'} (cached from a previous session).';
    }
    final when = _agoLabel(synced);
    final source = menu.usingCache ? ' — offline, using last cache' : '';
    return 'Menu: $count item${count == 1 ? '' : 's'} · synced $when$source';
  }

  String _agoLabel(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 5) return 'just now';
    if (s < 60) return '${s}s ago';
    final m = s ~/ 60;
    if (m < 60) return '${m}m ago';
    return '${m ~/ 60}h ago';
  }

  Widget _statusChip(HeadOfficeStatus status) {
    final (String label, Color bg, Color fg) = switch (status) {
      HeadOfficeStatus.online => (
          '● Online',
          AppColors.okGreenBg,
          AppColors.okGreenText
        ),
      HeadOfficeStatus.offline => (
          '○ Offline',
          AppColors.underBg,
          AppColors.underText
        ),
      HeadOfficeStatus.notConfigured => (
          'Not connected',
          AppColors.cream,
          AppColors.ink
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: fg, width: 2),
      ),
      child: Text(label,
          style: AppTextStyles.body(
              size: 12.5, weight: FontWeight.w700, color: fg)),
    );
  }

  Widget _field(String label, TextEditingController c, String hint,
      {bool obscure = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTextStyles.body(size: 13.5, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          keyboardType: TextInputType.url,
          style: AppTextStyles.mono(size: 14),
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            filled: true,
            fillColor: AppColors.white,
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.ink, width: 2),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppColors.green, width: 2.5),
            ),
          ),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------------
// Menu item weights — read-only view of what head office has published
// --------------------------------------------------------------------------

/// Menu item weights tab — a live, flexible search over the items and a
/// themed-scrollbar list, matching the shape of the old editable tab but
/// entirely read-only: there is no add/edit/delete here, since this app
/// never authors weights itself, it only ever reads or pulls them (set them
/// in the head-office portal, then use "Sync Menu" in the General tab). Tap
/// an item to see its modifiers, grouped exactly like the portal.
class _MenuWeightsTab extends ConsumerStatefulWidget {
  final double pad;
  const _MenuWeightsTab({required this.pad});

  @override
  ConsumerState<_MenuWeightsTab> createState() => _MenuWeightsTabState();
}

class _MenuWeightsTabState extends ConsumerState<_MenuWeightsTab> {
  final TextEditingController _searchC = TextEditingController();
  final ScrollController _listScroll = ScrollController();
  String _query = '';

  @override
  void dispose() {
    _searchC.dispose();
    _listScroll.dispose();
    super.dispose();
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Flexible filter: every whitespace token in the query must appear (as a
  /// substring) in the normalized name — so "ran sau" matches "Ranch Sauce",
  /// "ranch", "sauce", or the full name all work.
  List<MenuItem> _filter(List<MenuItem> items) {
    final q = _norm(_query);
    if (q.isEmpty) return items;
    final tokens = q.split(' ').where((t) => t.isNotEmpty).toList();
    return [
      for (final m in items)
        if (tokens.every((t) => _norm(m.name).contains(t))) m,
    ];
  }

  void _openModifiers(MenuItem item) {
    if (item.availableModifiers.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (_) => _ItemModifiersDialog(item: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The head-office menu is the ONLY thing that drives real weight-checks,
    // and this app never edits it locally — this tab is a pure viewer onto
    // whatever's currently loaded, so a background refresh (periodic, or
    // "Sync Menu") just updates the numbers in place without any of this
    // tab's own state (search text, scroll position) resetting.
    final headOfficeMenu = ref.watch(headOfficeMenuProvider);
    final items = List.of(headOfficeMenu.items)
      ..sort((a, b) => a.name.compareTo(b.name));
    final filtered = _filter(items);
    final pad = widget.pad;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 6, pad, 0),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.amber.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.ink, width: 1.5),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.lock_outline, size: 16, color: AppColors.ink),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Read-only — set weights in the head-office portal, '
                    'then "Sync Menu" in General settings.',
                    style: AppTextStyles.body(size: 11.5, weight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 6, pad, 0),
          child: _SearchField(
            controller: _searchC,
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 6, pad, 4),
          child: Text(
            _query.trim().isEmpty
                ? '${items.length} items'
                : '${filtered.length} of ${items.length} items',
            style: AppTextStyles.mono(
              size: 12,
              weight: FontWeight.w700,
              color: AppColors.muted,
            ),
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Text(
                    items.isEmpty
                        ? 'No menu synced yet. Connect to head office and '
                            'tap "Sync Menu" in General settings.'
                        : 'No items match "${_query.trim()}".',
                    textAlign: TextAlign.center,
                    style:
                        AppTextStyles.body(size: 15, color: AppColors.muted),
                  ),
                )
              : ThemedScrollbar(
                  controller: _listScroll,
                  child: ListView.builder(
                    controller: _listScroll,
                    padding: EdgeInsets.fromLTRB(pad, 2, pad, pad),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _MenuRow(
                        item: filtered[i],
                        onTap: () => _openModifiers(filtered[i]),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

/// Theme-matching, responsive search field with a live clear button.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.isNotEmpty;
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: AppTextStyles.body(size: 15, weight: FontWeight.w600),
      decoration: InputDecoration(
        isDense: true,
        filled: true,
        fillColor: AppColors.white,
        hintText: 'Search items',
        hintStyle: AppTextStyles.body(
          size: 14,
          color: AppColors.ink.withValues(alpha: 0.45),
        ),
        prefixIcon: const Icon(Icons.search, color: AppColors.ink, size: 20),
        suffixIcon: hasText
            ? IconButton(
                icon: const Icon(Icons.close, size: 18, color: AppColors.ink),
                tooltip: 'Clear',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
              )
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          borderSide: const BorderSide(color: AppColors.ink, width: 2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          borderSide: const BorderSide(color: AppColors.ink, width: 2.5),
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final MenuItem item;
  final VoidCallback onTap;
  const _MenuRow({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final totalMods = item.availableModifiers.length;
    final hasModifiers = totalMods > 0;
    final weighedMods =
        item.availableModifiers.where((m) => m.weightGrams != null).length;
    // An item can have its own ideal/range weight set while some of its
    // modifiers still don't — a selected-but-unweighed modifier still blocks
    // the weight check on any order that picks it, so that gap is surfaced
    // right here too, not only after staff hit a blocked order and wonder why
    // "the item shows weighed" didn't mean "fully ready to weigh".
    final modifiersIncomplete = hasModifiers && weighedMods < totalMods;
    final modsLabel =
        hasModifiers ? '$weighedMods of $totalMods modifiers weighed' : 'no modifiers';

    return Opacity(
      opacity: item.isActive ? 1 : 0.55,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: hasModifiers ? onTap : null,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            decoration: BoxDecoration(
              color: AppColors.cream,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.ink, width: 1.5),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          Text(item.name,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.body(
                                  size: 15.5, weight: FontWeight.w700)),
                          if (!item.isActive) _tag('Inactive'),
                          if (!item.isWeightConfigured) _tag('No weight'),
                          if (item.isWeightConfigured && modifiersIncomplete)
                            _tag('Modifiers incomplete', amber: true),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        !item.isWeightConfigured
                            ? 'No weight set · $modsLabel'
                            : item.hasRange
                                ? 'Ideal ${formatGrams(item.baseWeightGrams)} · range '
                                    '${formatGrams(item.minWeightGrams!)}–${formatGrams(item.maxWeightGrams!)}'
                                    ' · $modsLabel'
                                : 'Base ${formatGrams(item.baseWeightGrams)} · '
                                    'pkg ${formatGrams(item.packagingWeightGrams)} · '
                                    '$modsLabel',
                        style: AppTextStyles.mono(
                          size: 12.5,
                          color: AppColors.ink.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                if (hasModifiers)
                  const Icon(Icons.chevron_right, color: AppColors.ink),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tag(String text, {bool amber = false}) {
    final bg = amber ? AppColors.amber.withValues(alpha: 0.3) : AppColors.underBg;
    final fg = amber ? AppColors.ink : AppColors.underText;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: fg, width: 1.5),
      ),
      child: Text(text,
          style: AppTextStyles.body(size: 10.5, weight: FontWeight.w700, color: fg)),
    );
  }
}

/// Shows an item's real modifiers, grouped by their Foodics modifier group
/// (name + reference) exactly like the head-office portal's item drill-down —
/// each option's weight or "not weighed yet" status, greyed when inactive.
/// View-only: there is nothing to tap or edit here.
class _ItemModifiersDialog extends StatelessWidget {
  final MenuItem item;
  const _ItemModifiersDialog({required this.item});

  @override
  Widget build(BuildContext context) {
    // Group by reference (falls back to name, then a single "Modifiers"
    // bucket), preserving first-seen order — same grouping key the portal
    // uses, so the two views never disagree on how options are bucketed.
    final order = <String>[];
    final groups = <String, List<Modifier>>{};
    final groupLabel = <String, String>{};
    for (final m in item.availableModifiers) {
      final key = m.groupReference ?? m.groupName ?? '';
      if (!groups.containsKey(key)) {
        order.add(key);
        groups[key] = [];
        groupLabel[key] = m.groupName ?? 'Modifiers';
      }
      groups[key]!.add(m);
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: NeoCard(
          padding: const EdgeInsets.all(0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.name, style: AppTextStyles.display(size: 19)),
                          const SizedBox(height: 3),
                          Text(
                            '${item.availableModifiers.length} modifier'
                            '${item.availableModifiers.length == 1 ? '' : 's'}'
                            ' across ${order.length} group'
                            '${order.length == 1 ? '' : 's'}',
                            style: AppTextStyles.body(
                                size: 12.5, color: AppColors.muted),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: AppColors.ink),
                      tooltip: 'Close',
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.line),
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  shrinkWrap: true,
                  children: [
                    for (final key in order) ...[
                      Row(
                        children: [
                          Text(
                            groupLabel[key]!.toUpperCase(),
                            style: AppTextStyles.mono(
                              size: 11,
                              weight: FontWeight.w700,
                              color: AppColors.muted,
                              letterSpacing: 0.6,
                            ),
                          ),
                          if (key.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(key,
                                style: AppTextStyles.mono(
                                    size: 11, color: AppColors.muted)),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final mod in groups[key]!) _ModifierChip(mod: mod),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModifierChip extends StatelessWidget {
  final Modifier mod;
  const _ModifierChip({required this.mod});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: mod.isActive ? 1 : 0.55,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: BorderRadius.circular(AppShapes.pillRadius),
          border: Border.all(color: AppColors.ink, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(mod.name,
                style: AppTextStyles.body(size: 13.5, weight: FontWeight.w600)),
            const SizedBox(width: 8),
            Text(
              mod.weightGrams != null ? formatGrams(mod.weightGrams!) : 'not weighed',
              style: AppTextStyles.mono(
                size: 12,
                weight: FontWeight.w700,
                color: mod.weightGrams != null
                    ? AppColors.ink.withValues(alpha: 0.6)
                    : AppColors.underText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({
    required this.title,
    this.subtitle,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return NeoCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppTextStyles.display(size: 19)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle!,
                        style: AppTextStyles.body(
                          size: 13.5,
                          color: AppColors.ink.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// Weight source mode
// --------------------------------------------------------------------------

class _WeightSourceSection extends ConsumerWidget {
  final AppSettings settings;
  const _WeightSourceSection({required this.settings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = settings.weightSourceType;
    return _SectionCard(
      title: 'Weight source',
      subtitle: 'Choose where measured weights come from.',
      child: Column(
        children: [
          for (final type in WeightSourceType.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ModeRow(
                type: type,
                selected: current == type,
                onTap: () => ref
                    .read(settingsProvider.notifier)
                    .setWeightSourceType(type),
              ),
            ),
        ],
      ),
    );
  }
}

class _ModeRow extends StatelessWidget {
  final WeightSourceType type;
  final bool selected;
  final VoidCallback onTap;
  const _ModeRow({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final desc = switch (type) {
      WeightSourceType.manual =>
        'Type the weight by hand. Active stand-in while there is no scale.',
      WeightSourceType.serialStreaming =>
        'Scale pushes readings on its own, without polling. Not used by the '
            'Ariva\'s documented protocols — kept for other hardware.',
      WeightSourceType.serialPolling =>
        'App polls the scale (send W↵, read one response).',
    };

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected ? AppColors.okGreenBg : AppColors.cream,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppColors.ink,
              width: selected ? AppShapes.borderWidth : 1.5,
            ),
          ),
          child: Row(
            children: [
              _radio(selected),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          type.label,
                          style: AppTextStyles.body(
                            size: 15.5,
                            weight: FontWeight.w700,
                          ),
                        ),
                        if (type == WeightSourceType.manual) _tinyBadge('TEST'),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      desc,
                      style: AppTextStyles.body(
                        size: 13,
                        color: AppColors.ink.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _radio(bool on) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? AppColors.ink : AppColors.cream,
        border: Border.all(color: AppColors.ink, width: 2),
      ),
      child: on
          ? const Icon(Icons.check, size: 14, color: AppColors.cream)
          : null,
    );
  }

  Widget _tinyBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.amber,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: AppColors.ink, width: 1.5),
      ),
      child: Text(
        text,
        style: AppTextStyles.body(size: 10, weight: FontWeight.w700),
      ),
    );
  }
}

// --------------------------------------------------------------------------
// Serial connection settings
// --------------------------------------------------------------------------

class _SerialSection extends ConsumerWidget {
  final SerialSettings serial;
  const _SerialSection({required this.serial});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(settingsProvider.notifier);
    // Live status, not just a static "connect a scale" placeholder — this is
    // the actual signal staff (and whoever is wiring up the scale) need
    // during hardware bring-up: is the port open, and what did it last hear.
    final source = ref.watch(weightSourceProvider);
    final serialSource = source is SerialWeightSource ? source : null;
    final connected = serialSource?.isConnected ?? false;
    final statusLabel = serialSource?.statusLabel ??
        (kIsWeb || defaultTargetPlatform != TargetPlatform.android
            ? 'Serial scales only run on the Android app — use Manual mode '
                'here for preview.'
            : 'No scale connected.');
    final lastRaw = serialSource?.lastRawFrame ?? '';

    return _SectionCard(
      title: 'Serial connection',
      subtitle: 'These map to the scale\'s own setup menu. '
          'Stored ready for when hardware is connected.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: connected
                  ? AppColors.okGreenBg
                  : AppColors.amber.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.ink, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(connected ? Icons.usb : Icons.usb_off,
                    size: 20, color: AppColors.ink),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connected
                            ? statusLabel
                            : '$statusLabel Settings below are saved in the '
                                'meantime.',
                        style: AppTextStyles.body(
                            size: 13, weight: FontWeight.w600),
                      ),
                      if (connected && lastRaw.trim().isEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          'Port open, waiting on the first frame from the '
                          'scale…',
                          style: AppTextStyles.body(
                            size: 12,
                            color: AppColors.ink.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (lastRaw.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            _MonoBox(text: 'Last raw frame: ${_escapeControlChars(lastRaw)}'),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              _DropdownField<int>(
                label: 'Baud rate',
                value: serial.baudRate,
                options: SerialSettings.baudOptions,
                display: (v) => '$v',
                onChanged: (v) => notifier.setSerial(serial.copyWith(baudRate: v)),
              ),
              _DropdownField<String>(
                label: 'Parity',
                value: serial.parity,
                options: SerialSettings.parityOptions,
                display: (v) => v,
                onChanged: (v) => notifier.setSerial(serial.copyWith(parity: v)),
              ),
              _DropdownField<int>(
                label: 'Data bits',
                value: serial.dataBits,
                options: SerialSettings.dataBitOptions,
                display: (v) => '$v',
                onChanged: (v) => notifier.setSerial(serial.copyWith(dataBits: v)),
              ),
              _DropdownField<int>(
                label: 'Stop bits',
                value: serial.stopBits,
                options: SerialSettings.stopBitOptions,
                display: (v) => '$v',
                onChanged: (v) => notifier.setSerial(serial.copyWith(stopBits: v)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ProtocolField(
            value: serial.protocolName,
            onChanged: (v) =>
                notifier.setSerial(serial.copyWith(protocolName: v)),
          ),
          const SizedBox(height: 14),
          _MonoBox(text: 'Current: ${serial.summary}'),
        ],
      ),
    );
  }
}

class _ProtocolField extends StatefulWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _ProtocolField({required this.value, required this.onChanged});

  @override
  State<_ProtocolField> createState() => _ProtocolFieldState();
}

class _ProtocolFieldState extends State<_ProtocolField> {
  late final TextEditingController _c = TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_ProtocolField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same defensive resync as _HeadOfficeSectionState above: only follow an
    // external change if the field still shows what it was last set to, so
    // a live edit in progress is never overwritten.
    if (widget.value != oldWidget.value && _c.text == oldWidget.value) {
      _c.text = widget.value;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Protocol name',
            style: AppTextStyles.body(size: 13, weight: FontWeight.w700)),
        const SizedBox(height: 6),
        TextField(
          controller: _c,
          onChanged: widget.onChanged,
          style: AppTextStyles.body(size: 14, weight: FontWeight.w600),
          decoration: _fieldDecoration(),
        ),
      ],
    );
  }
}

// --------------------------------------------------------------------------
// Foodics POS integration
// --------------------------------------------------------------------------

class _FoodicsSection extends ConsumerStatefulWidget {
  final FoodicsSettings foodics;
  const _FoodicsSection({required this.foodics});

  @override
  ConsumerState<_FoodicsSection> createState() => _FoodicsSectionState();
}

class _FoodicsSectionState extends ConsumerState<_FoodicsSection> {
  FoodicsSettings get foodics => widget.foodics;
  SettingsController get notifier => ref.read(settingsProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final brandsAsync = ref.watch(foodicsBrandsProvider);
    final headOffice = ref.watch(headOfficeMenuProvider);
    final derived = headOffice.hasBrandBranch;
    final live = foodics.enabled &&
        (derived || foodics.isConfigured);

    return _SectionCard(
      title: 'Foodics POS',
      subtitle: derived
          ? 'Fetches live orders for this device\'s own registered branch.'
          : 'Fetch live orders per brand. While this is off, the app shows '
              'built-in sample orders so nothing breaks.',
      trailing: _StatusChip(
        text: live ? 'LIVE' : (foodics.enabled ? 'SETUP' : 'OFF'),
        color: live ? AppColors.okGreenBg : AppColors.amber,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Use live Foodics orders',
                    style:
                        AppTextStyles.body(size: 15, weight: FontWeight.w700)),
              ),
              Switch(
                value: foodics.enabled,
                activeThumbColor: AppColors.cream,
                activeTrackColor: AppColors.green,
                onChanged: (v) =>
                    notifier.setFoodics(foodics.copyWith(enabled: v)),
              ),
            ],
          ),
          if (kIsWeb) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: AppColors.amber.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.ink, width: 1.5),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 20, color: AppColors.ink),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Preview note: live Foodics runs in the Android app. This '
                      'web preview can\'t reach the API (browser CORS), so it '
                      'shows sample orders. Branches / menu sync work on the '
                      'tablet.',
                      style:
                          AppTextStyles.body(size: 12.5, weight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          if (derived)
            _derivedBrandBranch(headOffice)
          else
            brandsAsync.when(
              loading: () => const Text('Loading brands…'),
              error: (_, _) => Text('Could not load brands.',
                  style: AppTextStyles.body(size: 13)),
              data: (brands) => _brandAndBranch(brands),
            ),
          const SizedBox(height: 14),
          _NumberField(
            label: 'Poll interval',
            suffix: 's',
            value: foodics.pollSeconds.toDouble(),
            min: 5,
            max: 120,
            onChanged: (v) =>
                notifier.setFoodics(foodics.copyWith(pollSeconds: v.round())),
          ),
          const SizedBox(height: 14),
          _MonoBox(
            text: 'Status: ${derived ? _derivedSummary(headOffice) : foodics.summary}',
          ),
          const SizedBox(height: 10),
          Text(
            'This only drives the live order queue. Weights are managed '
            'centrally in the head-office portal — see "Sync Menu" above to '
            'pull the latest.',
            style: AppTextStyles.body(
              size: 12.5,
              color: AppColors.ink.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  /// The branch's human-readable label — prefers Foodics' own localized name,
  /// falling back to the plain branch name; a raw Foodics UUID is never
  /// something a person should have to read.
  String _branchLabel(HeadOfficeMenuState headOffice) {
    final name = headOffice.branchDisplayName;
    if (name != null && name.isNotEmpty) return name;
    return headOffice.foodicsBranchId != null ? 'this branch' : 'unknown branch';
  }

  String _derivedSummary(HeadOfficeMenuState headOffice) {
    if (!foodics.enabled) return 'Disabled — using sample orders';
    return 'Live — ${headOffice.brandCode} · ${_branchLabel(headOffice)} '
        '· every ${foodics.pollInterval.inSeconds}s';
  }

  /// Read-only — this device's own brand/branch, resolved server-side from
  /// its head-office registration. No picker: a device only ever weighs for
  /// (and now fetches live orders for) exactly the branch it was registered
  /// to in the portal, so the two can never silently disagree.
  Widget _derivedBrandBranch(HeadOfficeMenuState headOffice) {
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: AppColors.okGreenBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.ink, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lock_outline, size: 20, color: AppColors.ink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Brand ${headOffice.brandCode} · Branch ${_branchLabel(headOffice)}',
                  style:
                      AppTextStyles.body(size: 13.5, weight: FontWeight.w700),
                ),
                const SizedBox(height: 3),
                Text(
                  'Derived from this device\'s head-office registration — the '
                  'same brand/branch its weights come from, so live orders can '
                  'never point at a different brand by mistake.',
                  style: AppTextStyles.body(
                    size: 12.5,
                    color: AppColors.ink.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _brandAndBranch(List<FoodicsBrand> brands) {
    if (brands.isEmpty) {
      return Text(
        'No brands bundled. Add assets/foodics/brands.json (see the guide).',
        style: AppTextStyles.body(size: 13),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            _PickerField(
              label: 'Brand',
              placeholder: 'Choose brand',
              value: foodics.brandCode.isEmpty ? null : foodics.brandCode,
              options: [
                for (final b in brands) _Opt(b.code, '${b.name} (${b.code})'),
              ],
              onChanged: (code) => notifier.setFoodics(foodics.copyWith(
                brandCode: code,
                branchId: '',
                branchName: '',
              )),
            ),
            _branchPicker(),
          ],
        ),
      ],
    );
  }

  Widget _branchPicker() {
    if (foodics.brandCode.isEmpty) {
      return const _PickerField(
        label: 'Branch',
        placeholder: 'Choose a brand first',
        value: null,
        options: [],
        onChanged: _noop,
        enabled: false,
      );
    }
    final branchesAsync = ref.watch(foodicsBranchesProvider);
    return branchesAsync.when(
      loading: () => const _PickerField(
        label: 'Branch',
        placeholder: 'Loading…',
        value: null,
        options: [],
        onChanged: _noop,
        enabled: false,
      ),
      error: (e, _) => SizedBox(
        width: 260,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Branch',
                style: AppTextStyles.body(size: 13, weight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              e is FoodicsException
                  ? e.message
                  : 'Could not load branches — check the connection, then '
                      'reselect the brand.',
              style: AppTextStyles.body(size: 12.5, color: AppColors.underText),
            ),
          ],
        ),
      ),
      data: (branches) => _PickerField(
        label: 'Branch',
        placeholder: branches.isEmpty ? 'No branches' : 'Choose branch',
        value: foodics.branchId.isEmpty ? null : foodics.branchId,
        options: [for (final b in branches) _Opt(b.id, b.name)],
        onChanged: (id) {
          String name = '';
          for (final b in branches) {
            if (b.id == id) name = b.name;
          }
          notifier.setFoodics(
              foodics.copyWith(branchId: id, branchName: name));
        },
      ),
    );
  }

  static void _noop(String _) {}
}

class _Opt {
  final String value;
  final String label;
  const _Opt(this.value, this.label);
}

/// A themed dropdown that tolerates a null/absent current value (shows a
/// placeholder) — unlike a raw DropdownButton which asserts on unknown values.
class _PickerField extends StatelessWidget {
  final String label;
  final String placeholder;
  final String? value;
  final List<_Opt> options;
  final ValueChanged<String> onChanged;
  final bool enabled;

  const _PickerField({
    required this.label,
    required this.placeholder,
    required this.value,
    required this.options,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final known = options.any((o) => o.value == value);
    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: AppTextStyles.body(size: 13, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: enabled ? AppColors.white : AppColors.cream,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.ink, width: 1.5),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: known ? value : null,
                isExpanded: true,
                hint: Text(placeholder,
                    style: AppTextStyles.body(
                        size: 14,
                        color: AppColors.ink.withValues(alpha: 0.55))),
                style: AppTextStyles.body(size: 14, weight: FontWeight.w600),
                dropdownColor: AppColors.cream,
                items: [
                  for (final o in options)
                    DropdownMenuItem<String>(
                        value: o.value, child: Text(o.label)),
                ],
                onChanged: enabled ? (v) => v != null ? onChanged(v) : null : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --------------------------------------------------------------------------
// AI model info + metrics
// --------------------------------------------------------------------------

/// Status of the optional ML weight-prediction model — published from head
/// office, downloaded automatically (see WeightModelController), and used
/// only as a refinement of the built-in tolerance formula. Purely
/// informational: there is nothing to configure here, and every state shown
/// is a normal one — "not published" is not an error, it just means every
/// order is weight-checked with the built-in formula, exactly as before this
/// existed.
class _WeightModelSection extends ConsumerWidget {
  const _WeightModelSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final model = ref.watch(weightModelProvider);
    final (chipText, chipColor) = switch (model) {
      WeightModelState(available: true, :final version) =>
        ('v$version — active', AppColors.okGreenBg),
      WeightModelState(lastError: final err) when err != null =>
        ('fallback', AppColors.amber.withValues(alpha: 0.2)),
      _ => ('not published', AppColors.line),
    };

    return _SectionCard(
      title: 'Weight-prediction model',
      subtitle: 'An optional model, published from head office, that refines the '
          'expected weight for orders with no measured Min/Max standard. Falls '
          'back to the built-in formula whenever it isn\'t available.',
      trailing: _StatusChip(text: chipText, color: chipColor),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (model.available)
            Text(
              'Every weigh-check for an item with no exact Min/Max standard uses '
              'this model\'s prediction instead of the built-in tolerance formula.',
              style: AppTextStyles.body(size: 13.5),
            )
          else
            Text(
              model.lastError ??
                  'No model published for this brand yet — using the built-in '
                      'tolerance formula for every order.',
              style: AppTextStyles.body(size: 13.5),
            ),
          const SizedBox(height: 10),
          Text(
            'Publish or replace it from the portal (Brands → a brand → '
            '"AI model"); every scale on that brand picks it up automatically, '
            'no app update needed.',
            style: AppTextStyles.body(
              size: 12.5,
              color: AppColors.ink.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class _AiModelSection extends ConsumerWidget {
  const _AiModelSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metricsAsync = ref.watch(trainingMetricsProvider);
    final config = ref.watch(discrepancyConfigProvider).value;

    return _SectionCard(
      title: 'AI weight-check model',
      subtitle: 'On-device model that explains off-weight orders — what may be '
          'missing or extra, or whether the bag is the wrong order.',
      trailing: _StatusChip(
        text: 'v${config?.version ?? '—'}',
        color: AppColors.okGreenBg,
      ),
      child: metricsAsync.when(
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Text('Loading model metrics…'),
        ),
        error: (_, _) => _metricsUnavailable(),
        data: (m) => m == null ? _metricsUnavailable() : _metricsView(m),
      ),
    );
  }

  Widget _metricsUnavailable() => Text(
        'Trained metrics are not bundled. Run '
        '`dart run tool/train_discrepancy_model.dart` to (re)generate them.',
        style: AppTextStyles.body(size: 13.5),
      );

  Widget _metricsView(Map<String, dynamic> m) {
    double pct(String k) => ((m[k] as num?)?.toDouble() ?? 0) * 100;
    final trainedAt = m['trainedAt'] as String? ?? '—';
    final samples = (m['samples'] as num?)?.toInt() ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _StatTile(
                label: 'Top-1 accuracy',
                value: '${pct('strictTop1Accuracy').toStringAsFixed(1)}%'),
            _StatTile(
                label: 'Top-3 hit rate',
                value: '${pct('top3HitRate').toStringAsFixed(1)}%'),
            _StatTile(
                label: 'Class accuracy',
                value: '${pct('classAccuracy').toStringAsFixed(1)}%'),
            _StatTile(
                label: 'Brier (↓ better)',
                value: ((m['brierScore'] as num?)?.toDouble() ?? 0)
                    .toStringAsFixed(3)),
          ],
        ),
        const SizedBox(height: 14),
        _MonoBox(
          text: 'trained: $trainedAt\n'
              'test samples: $samples\n'
              'artifacts: assets/models/*.json',
        ),
        const SizedBox(height: 10),
        Text(
          'To update the model: retrain with the trainer script, or drop a new '
          'discrepancy_model.json into assets/models. The engine sits behind an '
          'interface, so a different model can be swapped in without UI changes.',
          style: AppTextStyles.body(
            size: 12.5,
            color: AppColors.ink.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  const _StatTile({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.okGreenBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.ink, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: AppTextStyles.mono(size: 20, weight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style: AppTextStyles.body(
                size: 12,
                weight: FontWeight.w600,
                color: AppColors.ink.withValues(alpha: 0.7),
              )),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String text;
  final Color color;
  const _StatusChip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppShapes.pillRadius),
        border: Border.all(color: AppColors.ink, width: 2),
      ),
      child: Text(
        text,
        style: AppTextStyles.mono(size: 12, weight: FontWeight.w700),
      ),
    );
  }
}

// --------------------------------------------------------------------------
// Reusable inputs
// --------------------------------------------------------------------------

InputDecoration _fieldDecoration({String? suffix}) {
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: AppColors.white,
    suffixText: suffix,
    suffixStyle: AppTextStyles.mono(
      size: 13,
      weight: FontWeight.w700,
      color: AppColors.ink.withValues(alpha: 0.6),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.ink, width: 1.5),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.ink, width: 2.5),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.coral, width: 2),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: const BorderSide(color: AppColors.coral, width: 2.5),
    ),
    errorStyle: AppTextStyles.body(
      size: 12,
      weight: FontWeight.w600,
      color: AppColors.underText,
    ),
  );
}

class _NumberField extends StatefulWidget {
  final String label;
  final String suffix;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _NumberField({
    required this.label,
    required this.suffix,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _c =
      TextEditingController(text: _fmt(widget.value));
  String? _error;

  String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  void _onChanged(String raw) {
    final parsed = double.tryParse(raw.trim());
    setState(() {
      if (raw.trim().isEmpty) {
        _error = 'Required';
      } else if (parsed == null) {
        _error = 'Numbers only';
      } else if (parsed < widget.min || parsed > widget.max) {
        _error = '${_fmt(widget.min)}–${_fmt(widget.max)}';
      } else {
        _error = null;
      }
    });
    if (_error == null && parsed != null) widget.onChanged(parsed);
  }

  @override
  void didUpdateWidget(_NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Same defensive resync as the other controllers in this file: only
    // follow an external change if the field still shows exactly what it
    // was last set to, so an in-progress edit is never overwritten.
    if (widget.value != oldWidget.value && _c.text == _fmt(oldWidget.value)) {
      _c.text = _fmt(widget.value);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.label,
              style: AppTextStyles.body(size: 13, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          TextField(
            controller: _c,
            onChanged: _onChanged,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            style: AppTextStyles.mono(size: 16, weight: FontWeight.w700),
            decoration: _fieldDecoration(suffix: widget.suffix).copyWith(
              errorText: _error,
            ),
          ),
        ],
      ),
    );
  }
}

class _DropdownField<T> extends StatelessWidget {
  final String label;
  final T value;
  final List<T> options;
  final String Function(T) display;
  final ValueChanged<T> onChanged;

  const _DropdownField({
    required this.label,
    required this.value,
    required this.options,
    required this.display,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 168,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTextStyles.body(size: 13, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.ink, width: 1.5),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<T>(
                value: value,
                isExpanded: true,
                borderRadius: BorderRadius.circular(12),
                style: AppTextStyles.mono(size: 15, weight: FontWeight.w700),
                dropdownColor: AppColors.cream,
                items: [
                  for (final o in options)
                    DropdownMenuItem<T>(value: o, child: Text(display(o))),
                ],
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Renders a raw serial frame's control bytes (STX, CR, ...) as visible
/// `<0xNN>` tokens instead of invisible characters, so a frame that looks
/// blank is actually readable while bringing up real hardware.
String _escapeControlChars(String raw) {
  final buffer = StringBuffer();
  for (final code in raw.codeUnits) {
    if (code < 0x20 || code == 0x7f) {
      buffer.write('<0x${code.toRadixString(16).padLeft(2, '0')}>');
    } else {
      buffer.writeCharCode(code);
    }
  }
  return buffer.toString();
}

class _MonoBox extends StatelessWidget {
  final String text;
  const _MonoBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.ink,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: AppTextStyles.mono(
          size: 14,
          weight: FontWeight.w400,
          color: AppColors.cream,
          height: 1.5,
        ),
      ),
    );
  }
}
