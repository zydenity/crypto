// lib/features/wallet/presentation/wallet_screen.dart
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../trade/ai_trade_screen.dart'; // add import (path relative to your file)
import '../../referrals/referral_program_screen.dart';

import '../../../services/api/wallet_api.dart';
import '../../../core/app_colors.dart';
import '../../../shared/widgets/balance_card.dart';
import '../../../shared/widgets/quick_actions.dart';
import '../../../shared/widgets/explore_row.dart';
import '../../../shared/widgets/promo_carousel.dart';
import 'receive_funds_screen.dart';

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen>
    with TickerProviderStateMixin {

  late final TabController _tabController;

  String? connectedAddress;
  double _available = 0.0; // verified/spendable
  double _pending = 0.0;   // pending deposits
  bool _loadingBal = true;
  bool _sendBusy = false;
  String? _ownerName;

  // --- history state ---
  bool _loadingHistory = true;
  List<_HistItem> _history = const [];




  Future<void> _bootstrap() async {
    try {
      final addr = await WalletApi.instance.getDefaultAddress();
      if (!mounted) return;
      setState(() => connectedAddress = addr);

      // NEW: get owner name
      final name = await WalletApi.instance.getOwnerName().catchError((_) => null);
      if (mounted) setState(() => _ownerName = (name?.trim().isEmpty ?? true) ? null : name!.trim());

      await _refreshAll();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingBal = false;
        _loadingHistory = false;
      });
    }
  }

  Future<void> _refreshAll() async {
    await Future.wait([_refreshBalance(), _loadHistory()]);

  }

  Future<void> _refreshBalance() async {
    final addr = connectedAddress;
    if (addr == null) return;
    setState(() => _loadingBal = true);
    try {
      final res = await WalletApi.instance.getBalance(
        address: addr,
        tokenSymbol: 'USDT',
      );

      double asDouble(dynamic v) {
        if (v is num) return v.toDouble();
        if (v is String) return double.tryParse(v) ?? 0.0;
        return 0.0;
      }

      if (!mounted) return;
      setState(() {
        _available = asDouble(res['available'] ?? res['verified'] ?? 0);
        _pending   = asDouble(res['pending'] ?? 0);
      });
    } finally {
      if (mounted) setState(() => _loadingBal = false);
    }
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      final results = await Future.wait([
        WalletApi.instance.listTransfers().catchError((_) => <Map<String,dynamic>>[]),
        WalletApi.instance.listBankTransfers().catchError((_) => <Map<String,dynamic>>[]),
        WalletApi.instance.listDeposits().catchError((_) => <Map<String,dynamic>>[]),
      ]);

      final transfers = (results[0] as List<Map<String, dynamic>>)
          .map<_HistItem>((m) => _HistItem.fromTransfer(m))
          .toList();

      final bankTx = (results[1] as List<Map<String, dynamic>>)
          .map<_HistItem>((m) => _HistItem.fromBankTransfer(m))
          .toList();

      final deposits = (results[2] as List<Map<String, dynamic>>)
          .map<_HistItem>((m) => _HistItem.fromDeposit(m))
          .toList();

      final merged = <_HistItem>[
        ...transfers, ...bankTx, ...deposits,
      ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (!mounted) return;
      setState(() {
        _history = merged;
      });
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  Future<void> _changeAddress() async {
    final controller = TextEditingController(text: connectedAddress ?? '');
    final newAddr = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set wallet address'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '0x...'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newAddr != null && newAddr.isNotEmpty) {
      final normalized = newAddr.toLowerCase();
      final valid = RegExp(r'^0x[a-fA-F0-9]{40}$').hasMatch(normalized);
      if (!valid) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid EVM address')),
        );
        return;
      }
      try {
        await WalletApi.instance.setDefaultAddress(normalized);
        if (!mounted) return;
        setState(() => connectedAddress = normalized);
        await _refreshAll();
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to save address: $e')));
      }
    }
  }

  Future<void> _openReceive() async {
    final addr = connectedAddress ?? '0x0000000000000000000000000000000000000000';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ReceiveFundsScreen(
          address: addr,
          tokenSymbol: 'USDT',
          network: 'Ethereum',
          tokenIconAsset: 'assets/icons/usdt.svg',
          erc20Contract: '0xdAC17F958D2ee523a2206206994597C13D831ec7',
          decimals: 6,
        ),
      ),
    );
    _refreshAll();
  }

  // ------------------------ SEND (sheet with spinner) ------------------------
  Future<void> _openSend() async {
    if (connectedAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect a wallet first')),
      );
      return;
    }

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final addrCtrl = TextEditingController();
        final amtCtrl  = TextEditingController();
        String network = 'ethereum';
        String? note;
        String? error;
        bool sending = false;

        bool validRecipient(String s) {
          final t = s.trim();
          if (RegExp(r'^0x[a-fA-F0-9]{40}$').hasMatch(t)) return true; // EVM
          if (RegExp(r'^T[1-9A-HJ-NP-Za-km-z]{25,34}$').hasMatch(t)) return true; // TRON (rough)
          return t.length >= 8;
        }

        bool canSend() {
          final a = double.tryParse(amtCtrl.text.trim()) ?? 0;
          return !sending && validRecipient(addrCtrl.text) && a > 0 && a <= _available;
        }

        return StatefulBuilder(
          builder: (ctx, setM) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16, right: 16, top: 16,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Send USDT', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),

                  TextField(
                    controller: addrCtrl,
                    onChanged: (_) => setM(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Recipient address',
                      hintText: '0x... / TR...',
                      prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),

                  TextField(
                    controller: amtCtrl,
                    onChanged: (_) => setM(() {}),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: 'Amount (USDT)',
                      helperText: 'Spendable: ${_fmtExact(_available)}',
                      prefixIcon: const Icon(Icons.attach_money_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    value: network,
                    items: const [
                      DropdownMenuItem(value: 'ethereum', child: Text('Ethereum (ERC20)')),
                      DropdownMenuItem(value: 'tron',     child: Text('TRON (TRC20)')),
                      DropdownMenuItem(value: 'bsc',      child: Text('BSC (BEP20)')),
                    ],
                    onChanged: (v) => setM(() => network = v ?? 'ethereum'),
                    decoration: const InputDecoration(labelText: 'Network'),
                  ),
                  const SizedBox(height: 12),

                  TextField(
                    onChanged: (v) => note = v.trim(),
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                      prefixIcon: Icon(Icons.note_outlined),
                    ),
                  ),

                  if (error != null) ...[
                    const SizedBox(height: 12),
                    Text(error!, style: const TextStyle(color: Colors.redAccent)),
                  ],

                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: canSend()
                        ? () async {
                      setM(() { sending = true; error = null; });
                      if (mounted) setState(() => _sendBusy = true);

                      final to = addrCtrl.text.trim();
                      final amount = double.tryParse(amtCtrl.text.trim()) ?? 0;

                      try {
                        await WalletApi.instance.createTransfer(
                          fromAddress: connectedAddress!,
                          toAddress: to,
                          amount: amount,
                          tokenSymbol: 'USDT',
                          network: network,
                          note: note,
                        );
                        if (context.mounted) {
                          Navigator.pop(ctx, true);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Transfer created: ${_fmtExact(amount)} USDT → ${to.substring(0,6)}…')),
                          );
                        }
                      } catch (e) {
                        setM(() { sending = false; error = 'Send failed: $e'; });
                        if (mounted) setState(() => _sendBusy = false);
                        return;
                      }

                      if (mounted) setState(() => _sendBusy = false);
                    }
                        : null,
                    child: sending
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Send'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (ok == true && mounted) {
      await _refreshAll();
    }
  }

  // ---------------------- BANK TRANSFER (sheet + preview) -------------------
  Future<void> _openBankTransfer() async {
    if (connectedAddress == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Connect a wallet first')),
      );
      return;
    }

    setState(() => _sendBusy = true);

    List<Map<String, dynamic>> banks = [];
    double rate = 0;

    const fallbackBanks = [
      {'code':'BDO','name':'BDO Unibank'},
      {'code':'BPI','name':'Bank of the Philippine Islands'},
      {'code':'MBTC','name':'Metrobank'},
      {'code':'LBP','name':'Land Bank of the Philippines'},
      {'code':'PNB','name':'Philippine National Bank'},
      {'code':'SECB','name':'Security Bank'},
      {'code':'CHIB','name':'China Bank'},
      {'code':'UBP','name':'UnionBank of the Philippines'},
      {'code':'RCBC','name':'RCBC'},
      {'code':'EWB','name':'EastWest Bank'},
      {'code':'AUB','name':'Asia United Bank'},
      {'code':'PSB','name':'PSBank'},
      {'code':'PBCOM','name':'PBCOM'},
      {'code':'BNCOM','name':'Bank of Commerce'},
      {'code':'MAYA','name':'Maya Bank, Inc.'},
      {'code':'CIMB','name':'CIMB Bank Philippines'},
      {'code':'TONIK','name':'Tonik Digital Bank'},
      {'code':'UNO','name':'UNO Digital Bank'},
      {'code':'OFB','name':'Overseas Filipino Bank'},
      {'code':'SEABANK','name':'SeaBank Philippines'},
      {'code':'GOTYME','name':'GoTyme Bank'},
    ];

    try {
      final api = WalletApi.instance;
      final results = await Future.wait([
        api.listBanks().catchError((_) => <Map<String,dynamic>>[]),
        api.getUsdtPhpRate().catchError((_) => 0.0),
      ]);
      banks = (results[0] as List<Map<String, dynamic>>);
      rate  = results[1] as double;
    } finally {
      if (mounted) setState(() => _sendBusy = false);
    }

    if (banks.isEmpty) banks = fallbackBanks;

    String? bankCode = banks.first['code'] as String;
    final accNumCtrl  = TextEditingController();
    final accNameCtrl = TextEditingController();
    final amtCtrl     = TextEditingController();
    String? note;
    bool sending = false;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) {
          final double amt = double.tryParse(amtCtrl.text.trim()) ?? 0.0;

          final double useRate = rate > 0 ? rate : 58.00;
          final double phpGross = amt * useRate;
          const double fxFeePct = 0.01;     // 1%
          const double payoutFeePhp = 25.0; // ₱25
          final double phpFees = phpGross * fxFeePct + payoutFeePhp;
          final double phpNet  = (phpGross - phpFees).clamp(0.0, double.infinity).toDouble();

          String php(num v) => '₱${v.toDouble().toStringAsFixed(2)}';

          return Padding(
            padding: EdgeInsets.only(
              left: 16, right: 16, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Bank Transfer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  value: bankCode,
                  items: banks.map((b) => DropdownMenuItem(
                    value: b['code'] as String,
                    child: Text(b['name'] as String),
                  )).toList(),
                  onChanged: (v) => setM(() => bankCode = v),
                  decoration: const InputDecoration(
                    labelText: 'Bank',
                    prefixIcon: Icon(Icons.account_balance_outlined),
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: accNameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Account name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: accNumCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Account number',
                    prefixIcon: Icon(Icons.numbers_outlined),
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: amtCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setM((){}),
                  decoration: InputDecoration(
                    labelText: 'Amount in USDT',
                    helperText: 'Spendable: ${_fmtExact(_available)}  •  Rate: ${useRate.toStringAsFixed(2)}/USDT',
                    prefixIcon: const Icon(Icons.attach_money_rounded),
                  ),
                ),
                const SizedBox(height: 12),

                // Conversion breakdown
                Card(
                  elevation: 0,
                  color: Colors.white.withOpacity(0.04),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Conversion', style: TextStyle(color: Colors.white.withOpacity(0.9), fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('USDT → PHP'),
                          Text('${amt.toStringAsFixed(2)} × ${useRate.toStringAsFixed(2)} = ${php(phpGross)}'),
                        ]),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('FX fee (1%) + payout (₱25)'),
                          Text('- ${php(phpFees)}'),
                        ]),
                        const Divider(height: 16),
                        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          const Text('You receive', style: TextStyle(fontWeight: FontWeight.w700)),
                          Text(php(phpNet), style: const TextStyle(fontWeight: FontWeight.w700)),
                        ]),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 12),

                FilledButton(
                  onPressed: sending ? null : () async {
                    final toSend = amt;
                    if (bankCode == null ||
                        accNameCtrl.text.trim().isEmpty ||
                        accNumCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Fill in all bank details')),
                      );
                      return;
                    }
                    if (toSend <= 0 || toSend > _available) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Invalid amount. Spendable: ${_fmtExact(_available)}')),
                      );
                      return;
                    }
                    setM(() => sending = true);
                    try {
                      await WalletApi.instance.createBankTransfer(
                        fromAddress: connectedAddress!,
                        bankCode: bankCode!,
                        accountNumber: accNumCtrl.text.trim(),
                        accountName: accNameCtrl.text.trim(),
                        amountUsdt: toSend,
                        rateUsdtPhp: rate > 0 ? rate : null,
                        note: note,
                      );
                      if (!mounted) return;
                      Navigator.pop(ctx);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Transfer queued: ${_fmtExact(toSend)} USDT → $bankCode')),
                      );
                      await _refreshAll(); // available drops + history updates
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Bank transfer failed: $e')),
                      );
                    } finally {
                      if (mounted) setM(() => sending = false);
                    }
                  },
                  child: sending
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Send to Bank'),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ----------------------------- helpers & UI -------------------------------
  // Print exact amount (up to 6 decimals), no trailing zeros/dot.
// Print with up to 2 decimals (rounds to 2, then trims trailing zeros and dot).
  String _fmtExact(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), ''); }

  String _shortAddr(String a) => "${a.substring(0, 6)}…${a.substring(a.length - 4)}";

  String _fmtDate(DateTime dt) {
    final d = dt.toLocal();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return "$mm/$dd $hh:$mi";
  }

  Color _statusColor(String s) {
    switch (s.toLowerCase()) {
      case 'pending':
      case 'processing':
      case 'broadcast':
        return Colors.orangeAccent;
      case 'confirmed':
      case 'received':
      case 'verified':
        return Colors.greenAccent;
      case 'failed':
      case 'rejected':
        return Colors.redAccent;
      case 'sent':
        return Colors.blueAccent;
      default:
        return Colors.white70;
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final balanceText = connectedAddress == null
        ? 'USDT 0'
        : _loadingBal
        ? 'USDT …'
        : 'USDT ${_fmtExact(_available)}';

    final subtitle = connectedAddress == null
        ? 'Available'
        : _pending > 0
        ? '${_shortAddr(connectedAddress!)} · Pending ${_fmtExact(_pending)} USDT'
        : _shortAddr(connectedAddress!);

    return RefreshIndicator(
      onRefresh: _refreshAll,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverAppBar(
            pinned: true,
            title: Row(
              children: [
                Container(
                  width: 32, height: 32,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                  padding: const EdgeInsets.all(6),
                  child: SvgPicture.asset('assets/icons/usdt.svg'),
                ),
                const SizedBox(width: 10),
                Text(
                  _ownerName ?? (connectedAddress != null ? _shortAddr(connectedAddress!) : 'Wallet'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'Refresh',
                onPressed: _refreshAll,
                icon: const Icon(Icons.refresh_rounded),
              ),
              Padding(
                padding: const EdgeInsets.only(right: 12.0),
                child: FilledButton.tonal(
                  onPressed: _changeAddress,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.primary.withValues(alpha: .15),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                  ),
                  child: const Text('CryptoAI', style: TextStyle(color: Colors.white)),

                ),
              ),
            ],

          ),

          // Body
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  BalanceCard(
                    balanceText: balanceText,
                    subtitle: subtitle,
                    tokenIconAsset: 'assets/icons/usdt.svg',
                    headerLabel: 'USDT  •  AVAILABLE BALANCE',
                    onPrimary: _openReceive,
                  ),
                  const SizedBox(height: 16),
                  QuickActionsGrid(actions: [
                    QuickAction('Send', FontAwesomeIcons.paperPlane, AppColors.accent, () { if (_sendBusy) return; _openSend(); }),
                    QuickAction('Bank Transfer', FontAwesomeIcons.downLong, AppColors.primary, () { if (_sendBusy) return; _openBankTransfer(); }),
                    QuickAction('AI Trade', FontAwesomeIcons.rightLeft, AppColors.primary, () {
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AiTradeScreen()));
                    }),
                    // ↓ Navigate to the new Referral page
                    QuickAction('Referral', FontAwesomeIcons.gift, AppColors.accent, () {
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ReferralProgramScreen()));
                    }),
                  ]),

                  const SizedBox(height: 20),

                  const SizedBox(height: 12),

                  const SizedBox(height: 20),

                  // ---------------------------- History ----------------------------
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: const [
                      Text('Recent activity', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 10),

                  if (_loadingHistory)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_history.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Text('No activity yet', style: TextStyle(color: Colors.white.withOpacity(0.7))),
                    )
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _history.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (_, i) {
                        final h = _history[i];
                        final amtStr = '${h.isOut ? '-' : '+'} ${_fmtExact(h.amount)} ${h.token}';
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
                          leading: CircleAvatar(
                            radius: 20,
                            backgroundColor: Colors.white.withOpacity(0.08),
                            child: Icon(h.icon, color: Colors.white),
                          ),
                          title: Text(h.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: _statusColor(h.status).withOpacity(.15),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(h.status, style: TextStyle(color: _statusColor(h.status), fontSize: 12, fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text('${h.subtitle} • ${_fmtDate(h.createdAt)}',
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withOpacity(.7))),
                              ),
                            ],
                          ),
                          trailing: Text(
                            amtStr,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: h.isOut ? Colors.white : Colors.greenAccent,
                            ),
                          ),
                        );
                      },
                    ),

                  const SizedBox(height: 80),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Unified history item
class _HistItem {
  final String type;         // 'send' | 'bank' | 'deposit'
  final String title;
  final String subtitle;
  final double amount;       // USDT amount
  final String token;        // 'USDT'
  final bool isOut;          // outgoing?
  final String status;
  final DateTime createdAt;
  final IconData icon;

  _HistItem({
    required this.type,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.token,
    required this.isOut,
    required this.status,
    required this.createdAt,
    required this.icon,
  });

  static DateTime _dt(dynamic v) {
    if (v is String) {
      try { return DateTime.parse(v); } catch (_) {}
    }
    return DateTime.now();
  }

  static String _short(String a) {
    if (a.length <= 10) return a;
    return '${a.substring(0,6)}…${a.substring(a.length-4)}';
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  factory _HistItem.fromTransfer(Map<String, dynamic> m) {
    final to = (m['toAddress'] ?? '').toString();
    final net = (m['network'] ?? '').toString().toUpperCase();
    final st  = (m['status'] ?? '').toString().toLowerCase();
    String label;
    switch (st) {
      case 'pending':   label = 'Processing'; break;
      case 'broadcast': label = 'Sent';       break;
      case 'confirmed': label = 'Received';   break;
      case 'failed':    label = 'Failed';     break;
      case 'rejected':  label = 'Rejected';   break;
      default:          label = st.isEmpty ? 'Processing' : st;
    }
    return _HistItem(
      type: 'send',
      title: 'Send',
      subtitle: '${_short(to)} • $net',
      amount: _toDouble(m['amount']),
      token: (m['tokenSymbol'] ?? 'USDT').toString(),
      isOut: true,
      status: label,
      createdAt: _dt(m['createdAt']),
      icon: FontAwesomeIcons.paperPlane,
    );
  }

  factory _HistItem.fromBankTransfer(Map<String, dynamic> m) {
    final bank = (m['bankCode'] ?? '').toString();
    final st   = (m['status'] ?? '').toString().toLowerCase();
    String label;
    switch (st) {
      case 'processing': label = 'Processing'; break;
      case 'sent':       label = 'Sent';       break;
      case 'received':   label = 'Received';   break;
      case 'failed':     label = 'Failed';     break;
      case 'canceled':   label = 'Canceled';   break;
      default:           label = st.isEmpty ? 'Processing' : st;
    }
    return _HistItem(
      type: 'bank',
      title: 'Bank transfer',
      subtitle: bank,
      amount: _toDouble(m['amountUsdt']),
      token: (m['tokenSymbol'] ?? 'USDT').toString(),
      isOut: true,
      status: label,
      createdAt: _dt(m['createdAt']),
      icon: FontAwesomeIcons.buildingColumns,
    );
  }

  factory _HistItem.fromDeposit(Map<String, dynamic> m) {
    final st = (m['status'] ?? '').toString().toLowerCase();
    String label;
    switch (st) {
      case 'pending':  label = 'Pending';  break;
      case 'verified': label = 'Verified'; break;
      case 'rejected': label = 'Rejected'; break;
      default:         label = st;
    }
    final addr = (m['address'] ?? '').toString();
    final net  = (m['network'] ?? '').toString().toUpperCase();
    return _HistItem(
      type: 'deposit',
      title: 'Deposit',
      subtitle: '${_short(addr)} • $net',
      amount: _toDouble(m['amount']),
      token: (m['tokenSymbol'] ?? 'USDT').toString(),
      isOut: false,
      status: label,
      createdAt: _dt(m['createdAt']),
      icon: FontAwesomeIcons.arrowDownLong,
    );
  }
}
