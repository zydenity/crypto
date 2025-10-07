import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../../core/app_colors.dart';
import '../../services/api/wallet_api.dart';

class ReferralProgramScreen extends StatefulWidget {
  const ReferralProgramScreen({super.key});

  @override
  State<ReferralProgramScreen> createState() => _ReferralProgramScreenState();
}

class _ReferralProgramScreenState extends State<ReferralProgramScreen> {
  bool _loading = true;

  // Summary
  String _code = '';
  String _link = '';
  double _totalCommissions = 0.0;
  double _pendingCommissions = 0.0;
  int _referredCount = 0;
  String _tier = 'Starter';

  // Rates (display only; override if API returns values)
  double _rateLevel1Pct = 20;
  double _rateLevel2Pct = 5;

  // Lists
  List<Map<String, dynamic>> _referrals = [];
  List<Map<String, dynamic>> _commissions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  String _fmtUsdt(num v) => 'USDT ${v.toDouble().toStringAsFixed(2)}';

  String _dateOnly(dynamic s) {
    if (s == null) return '';
    final str = '$s';
    final idxT = str.indexOf('T');
    final idxSp = str.indexOf(' ');
    if (idxT > 0) return str.substring(0, idxT);
    if (idxSp > 0) return str.substring(0, idxSp);
    return str;
  }

  Future<void> _load() async {
    setState(() => _loading = true);

    // NOTE: we call WalletApi dynamically so this file compiles
    // even if your API layer doesn’t have these methods yet.
    // Add them when ready; these calls will start returning data.
    try {
      final api = WalletApi.instance as dynamic;

      // SUMMARY
      try {
        final m = await api.getReferralSummary(); // <- implement in WalletApi
        if (mounted && m is Map) {
          setState(() {
            _code               = (m['code'] ?? _code).toString();
            _link               = (m['link'] ?? _link).toString();
            _totalCommissions   = _asDouble(m['totalCommissionsUsdt']);
            _pendingCommissions = _asDouble(m['pendingCommissionsUsdt']);
            _referredCount      = (m['referredCount'] as num?)?.toInt() ?? _referredCount;
            _tier               = (m['tier'] ?? _tier).toString();

            // Optional rates from API
            if (m['level1RatePct'] != null) {
              _rateLevel1Pct = _asDouble(m['level1RatePct']);
            }
            if (m['level2RatePct'] != null) {
              _rateLevel2Pct = _asDouble(m['level2RatePct']);
            }
          });
        }
      } catch (_) {
        // Fallback demo values (you can remove when API is ready)
        final demoHost = 'https://app.example.com';
        setState(() {
          _code = _code.isNotEmpty ? _code : 'YOURCODE';
          _link = _link.isNotEmpty ? _link : '$demoHost/r/YOURCODE';
          _totalCommissions = _totalCommissions > 0 ? _totalCommissions : 0.00;
          _pendingCommissions = _pendingCommissions > 0 ? _pendingCommissions : 0.00;
          _referredCount = _referredCount > 0 ? _referredCount : 0;
          _tier = _tier.isNotEmpty ? _tier : 'Starter';
        });
      }

      // REFERRALS LIST
      try {
        final rows = await api.listReferrals(); // <- implement in WalletApi
        if (mounted && rows is List) {
          setState(() => _referrals = rows.cast<Map<String, dynamic>>());
        }
      } catch (_) {
        // ignore
      }

      // COMMISSIONS LIST
      try {
        final rows = await api.listReferralCommissions(); // <- implement in WalletApi
        if (mounted && rows is List) {
          setState(() => _commissions = rows.cast<Map<String, dynamic>>());
        }
      } catch (_) {
        // ignore
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _copy(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Referral Program', style: TextStyle(fontWeight: FontWeight.w700)),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // --- HERO / LINK / CODE ---
            Container(
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: const [
                    Icon(FontAwesomeIcons.gift, size: 18),
                    SizedBox(width: 8),
                    Text('Invite & Earn', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  ]),
                  const SizedBox(height: 10),
                  Text(
                    'Share your link. When friends trade, you earn a percentage of their fees.',
                    style: TextStyle(color: Colors.white.withOpacity(.75)),
                  ),
                  const SizedBox(height: 14),

                  // Referral code
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(.06),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('Code:', style: TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(width: 8),
                            Text(_code.isEmpty ? '—' : _code, style: const TextStyle(letterSpacing: .5)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      OutlinedButton.icon(
                        onPressed: _code.isEmpty ? null : () => _copy(_code, 'Referral code'),
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('Copy code'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Referral link
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.04),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _link.isEmpty ? 'Referral link will appear here' : _link,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          tooltip: 'Copy link',
                          onPressed: _link.isEmpty ? null : () => _copy(_link, 'Referral link'),
                          icon: const Icon(Icons.copy),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // --- STATS ---
            Row(children: const [
              Text('Your stats', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _StatCard(title: 'Total commissions', value: _fmtUsdt(_totalCommissions))),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(title: 'Pending', value: _fmtUsdt(_pendingCommissions))),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _StatCard(title: 'Referrals', value: '$_referredCount')),
                const SizedBox(width: 10),
                Expanded(child: _StatCard(title: 'Tier', value: _tier)),
              ],
            ),

            const SizedBox(height: 16),

            // --- COMMISSION RATES ---
            Row(children: const [
              Text('Commission rates', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: AppColors.card,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                children: [
                  _RateRow(label: 'Level 1 (direct)', pct: _rateLevel1Pct),
                  const Divider(height: 1, color: Colors.white12),
                  _RateRow(label: 'Level 2 (friends of friends)', pct: _rateLevel2Pct),
                ],
              ),
            ),

            const SizedBox(height: 16),

            // --- MECHANICS ---
            Row(children: const [
              Text('How it works', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ]),
            const SizedBox(height: 8),
            _MechanicsCard(items: const [
              'Share your referral link or code.',
              'Your friend signs up and starts trading.',
              'You earn a percentage of their trading fees in real time.',
              'Higher tiers unlock higher commission rates.',
            ]),

            const SizedBox(height: 16),

            // --- REFERRALS LIST ---
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              collapsedIconColor: Colors.white70,
              iconColor: Colors.white70,
              title: const Text('Your referrals', style: TextStyle(fontWeight: FontWeight.w700)),
              children: [
                if (_referrals.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                    child: Text('No referrals yet', style: TextStyle(color: Colors.white.withOpacity(.7))),
                  )
                else
                  ..._referrals.map((r) {
                    final uid = (r['refereeCode'] ?? '').toString();
                    final joined = _dateOnly(r['joinedAt'] ?? r['createdAt']);
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(FontAwesomeIcons.user),
                      title: Text(uid.isEmpty ? 'Friend' : uid),
                      subtitle: Text('Joined: $joined', style: TextStyle(color: Colors.white.withOpacity(.7))),
                    );
                  }).toList(),
              ],
            ),

            const SizedBox(height: 8),

            // --- COMMISSIONS LIST ---
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              collapsedIconColor: Colors.white70,
              iconColor: Colors.white70,
              title: const Text('Commission history', style: TextStyle(fontWeight: FontWeight.w700)),
              children: [
                if (_commissions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 0, 12),
                    child: Text('No commissions yet', style: TextStyle(color: Colors.white.withOpacity(.7))),
                  )
                else
                  ..._commissions.map((m) {
                    final amt = _asDouble(m['amountUsdt'] ?? m['amount']);
                    final ts = _dateOnly(m['createdAt']);
                    final st = (m['status'] ?? 'credited').toString();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(FontAwesomeIcons.coins),
                      title: Text(_fmtUsdt(amt), style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('$st • $ts', style: TextStyle(color: Colors.white.withOpacity(.7))),
                    );
                  }).toList(),
              ],
            ),

            const SizedBox(height: 24),

            // TERMS
            Text(
              'By participating, you agree to the Referral Program Terms. '
                  'Self-referrals and abuse are not allowed. Rates and mechanics may change.',
              style: TextStyle(color: Colors.white.withOpacity(.6), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  const _StatCard({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(color: Colors.white.withOpacity(.7))),
          const SizedBox(height: 6),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        ],
      ),
    );
  }
}

class _RateRow extends StatelessWidget {
  final String label;
  final double pct;
  const _RateRow({required this.label, required this.pct});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.greenAccent.withOpacity(.16),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.greenAccent.withOpacity(.35)),
        ),
        child: Text('${pct.toStringAsFixed(0)}%',
            style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.greenAccent)),
      ),
    );
  }
}

class _MechanicsCard extends StatelessWidget {
  final List<String> items;
  const _MechanicsCard({required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < items.length; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 24, height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(.06),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 10),
                Expanded(child: Text(items[i])),
              ],
            ),
            if (i != items.length - 1) const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
