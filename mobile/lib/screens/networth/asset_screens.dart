import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/format.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../widgets/common.dart';
import '../../widgets/entity_form.dart';
import 'finance_shared.dart';

/// Types whose extra detail fields (location, size, registration) apply.
const majorAssetTypes = {'property', 'land', 'house', 'business', 'vehicle'};

IconData assetIcon(String type) => switch (type) {
      'cash' => Icons.payments_outlined,
      'bank' => Icons.account_balance_outlined,
      'investment' => Icons.trending_up,
      'property' => Icons.apartment_outlined,
      'land' => Icons.landscape_outlined,
      'house' => Icons.home_outlined,
      'business' => Icons.storefront_outlined,
      'vehicle' => Icons.directions_car_outlined,
      _ => Icons.category_outlined,
    };

class AssetTile extends StatelessWidget {
  const AssetTile({super.key, required this.asset, required this.symbol, required this.onTap});
  final Asset asset;
  final String symbol;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final a = asset;
    final details = [
      a.assetTypeDisplay,
      if (a.isMajor && a.location.isNotEmpty) a.location,
      if (a.isMajor && a.size.isNotEmpty) a.size,
    ].join(' · ');
    return ListTile(
      onTap: onTap,
      leading: IconBadge(iconData: assetIcon(a.assetType), color: '#198754', size: 38),
      title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(fmtIn(a.value, a.currency, symbol),
          style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}

/// One asset with its full details.
class AssetDetailScreen extends StatefulWidget {
  const AssetDetailScreen({super.key, required this.asset});
  final Asset asset;

  @override
  State<AssetDetailScreen> createState() => _AssetDetailScreenState();
}

class _AssetDetailScreenState extends State<AssetDetailScreen> {
  final _loader = GlobalKey<LoadBuilderState<Asset>>();
  late Asset _asset = widget.asset;

  Session get _session => context.read<Session>();
  String get _path => 'assets/${widget.asset.id}/';

  Future<Asset> _load() async {
    final a = Asset.fromJson(await _session.api.get(_path) as Map<String, dynamic>);
    if (mounted) setState(() => _asset = a);
    return a;
  }

  Future<void> _edit() async {
    if (await openAssetForm(context, existing: _asset)) _loader.currentState?.reload();
  }

  Future<void> _delete() async {
    final ok = await confirmDelete(
      context,
      title: 'Delete "${_asset.name}"?',
      message: 'It will no longer count towards your net worth.',
      action: () => _session.api.delete(_path),
      success: 'Asset deleted',
    );
    if (ok && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final symbol = context.watch<Session>().currencySymbol;
    return Scaffold(
      appBar: AppBar(
        title: Text(_asset.name),
        actions: [EditDeleteMenu(onEdit: _edit, onDelete: _delete)],
      ),
      body: LoadBuilder<Asset>(
        key: _loader,
        load: _load,
        builder: (context, a, reload) => ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  IconBadge(iconData: assetIcon(a.assetType), color: '#198754', size: 52),
                  const SizedBox(width: 16),
                  Expanded(
                    child: HeadlineAmount(
                      caption: a.assetTypeDisplay,
                      amount: fmtIn(a.value, a.currency, symbol),
                      color: AppColors.income,
                    ),
                  ),
                ]),
              ),
            ),
            const SizedBox(height: 12),
            InfoCard(rows: [
              ('Type', a.assetTypeDisplay),
              ('Currency', a.currency?.code ?? ''),
              ('Acquired', a.acquisitionDate == null ? '' : fmtDate(a.acquisitionDate)),
              ('Location', a.location),
              ('Size', a.size),
              ('Registration no.', a.registrationNumber),
              ('Notes', a.notes),
            ]),
          ],
        ),
      ),
    );
  }
}

/// Create ([existing] null) or edit an asset. Resolves true when saved.
Future<bool> openAssetForm(BuildContext context, {Asset? existing}) {
  bool isMajor(Map<String, dynamic> v) => majorAssetTypes.contains(v['asset_type']);
  return openMetaForm(context, (meta, session) {
    final r = existing?.raw;
    return EntityFormScreen(
      title: existing == null ? 'Add asset' : 'Edit asset',
      initial: r == null
          ? {'asset_type': 'bank', 'currency': session.household?.baseCurrency?.id}
          : {
              'name': r['name'],
              'asset_type': r['asset_type'],
              'value': r['value'],
              'currency': existing!.currency?.id,
              'acquisition_date': r['acquisition_date'],
              'location': r['location'],
              'size': r['size'],
              'registration_number': r['registration_number'],
              'notes': r['notes'],
            },
      fields: [
        const FieldSpec.text('name', 'Name', required: true, hint: 'e.g. CRDB savings account'),
        FieldSpec.select('asset_type', 'Type',
            options: choiceOptions(meta, 'asset_type'), required: true),
        const FieldSpec.money('value', 'Current value', required: true),
        FieldSpec.select('currency', 'Currency', options: currencyOptions(meta)),
        FieldSpec.date('acquisition_date', 'Acquisition date', visibleWhen: isMajor),
        FieldSpec.text('location', 'Location', hint: 'e.g. Plot 17, Mikocheni', visibleWhen: isMajor),
        FieldSpec.text('size', 'Size',
            hint: 'e.g. 120 m², 0.5 acre, 3 bed / 2 bath', visibleWhen: isMajor),
        FieldSpec.text('registration_number', 'Registration number',
            hint: 'Title deed / plate / licence no.', visibleWhen: isMajor),
        const FieldSpec.multiline('notes', 'Notes'),
      ],
      onSubmit: (v) => existing == null
          ? session.api.post('assets/', v)
          : session.api.patch('assets/${existing.id}/', v),
    );
  });
}
