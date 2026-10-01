import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../debts/debts_screen.dart';
import '../lent/lent_screen.dart';
import 'asset_screens.dart';
import 'networth_widgets.dart';

/// Assets + money lent − liabilities, with history and the asset register.
class NetWorthScreen extends StatefulWidget {
  const NetWorthScreen({super.key});

  @override
  State<NetWorthScreen> createState() => _NetWorthScreenState();
}

class _NetWorthScreenState extends State<NetWorthScreen> {
  final _loader = GlobalKey<LoadBuilderState<NetWorth>>();
  bool _saving = false;

  Session get _session => context.read<Session>();

  Future<NetWorth> _load() async =>
      NetWorth.fromJson(await _session.api.get('networth/') as Map<String, dynamic>);

  Future<void> _reload() async => _loader.currentState?.reload();

  Future<void> _snapshot() async {
    setState(() => _saving = true);
    final ok = await runAction(context, () => _session.api.post('networth/snapshot/'),
        success: "Snapshot saved for today");
    if (!mounted) return;
    setState(() => _saving = false);
    if (ok) _reload();
  }

  Future<void> _addAsset() async {
    if (await openAssetForm(context)) _reload();
  }

  Future<void> _openAsset(Asset a) async {
    await push(context, AssetDetailScreen(asset: a));
    _reload();
  }

  Future<void> _go(Widget screen) async {
    await push(context, screen);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Net worth'),
        actions: [
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                      width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  tooltip: 'Save snapshot',
                  icon: const Icon(Icons.add_chart),
                  onPressed: _snapshot,
                ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addAsset,
        icon: const Icon(Icons.add),
        label: const Text('Add asset'),
      ),
      body: LoadBuilder<NetWorth>(
        key: _loader,
        load: _load,
        builder: (context, nw, reload) => ListView(
          padding: const EdgeInsets.only(top: 12, bottom: 96),
          children: [
            NetWorthHeadline(data: nw, symbol: symbol),
            const SizedBox(height: 8),
            StatRow(children: [
              _Tappable(
                child: StatTile(
                    label: 'Assets',
                    value: fmtMoney(nw.totalAssets, symbol: symbol),
                    color: AppColors.income,
                    icon: Icons.account_balance_wallet_outlined),
              ),
              _Tappable(
                onTap: () => _go(const LentScreen()),
                child: StatTile(
                    label: 'Money lent',
                    value: fmtMoney(nw.totalReceivables, symbol: symbol),
                    color: AppColors.info,
                    icon: Icons.handshake_outlined),
              ),
              _Tappable(
                onTap: () => _go(const DebtsScreen()),
                child: StatTile(
                    label: 'Liabilities',
                    value: fmtMoney(nw.totalLiabilities, symbol: symbol),
                    color: AppColors.expense,
                    icon: Icons.credit_card),
              ),
            ]),
            SectionHeader('Net worth over time',
                trailing: TextButton(
                    onPressed: _saving ? null : _snapshot, child: const Text('Save snapshot'))),
            SnapshotChartCard(snapshots: nw.snapshots, symbol: symbol),
            if (nw.assetsByType.isNotEmpty) ...[
              const SectionHeader('Assets by type'),
              BreakdownCard(values: nw.assetsByType, color: AppColors.income, symbol: symbol),
            ],
            SectionHeader('Assets (${nw.assets.length})'),
            if (nw.assets.isEmpty)
              _EmptyAssets(onAdd: _addAsset)
            else
              Card(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(children: [
                  for (final a in nw.assets)
                    AssetTile(asset: a, symbol: symbol, onTap: () => _openAsset(a)),
                ]),
              ),
            SectionHeader('Liabilities',
                trailing: TextButton(
                    onPressed: () => _go(const DebtsScreen()), child: const Text('Manage'))),
            LiabilitySummaryCard(
              data: nw,
              symbol: symbol,
              onOpen: () => _go(const DebtsScreen()),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tappable extends StatelessWidget {
  const _Tappable({required this.child, this.onTap});
  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) =>
      onTap == null ? child : GestureDetector(onTap: onTap, child: child);
}

class _EmptyAssets extends StatelessWidget {
  const _EmptyAssets({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          const Text('No assets recorded yet. Add bank accounts, cash, property or vehicles.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
              onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Add asset')),
        ]),
      ),
    );
  }
}
