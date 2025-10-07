import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';
import '../../../services/api/wallet_api.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  bool _loading = true;
  String? _error;
  List<TxRowData> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final addr = await WalletApi.instance.getDefaultAddress();
      if (!mounted) return;
      if (addr == null || addr.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'No wallet address set.';
        });
        return;
      }

      final results = await Future.wait([
        WalletApi.instance.listTransfers().catchError((_) => <Map<String, dynamic>>[]),
        WalletApi.instance.listBankTransfers().catchError((_) => <Map<String, dynamic>>[]),
        // deposits can be filtered by address; fallback works too
        WalletApi.instance.listDeposits(address: addr).catchError((_) => <Map<String, dynamic>>[]),
      ]);

      final transfers = (results[0] as List<Map<String, dynamic>>)
          .map<TxRowData>(_txFromTransfer)
          .toList();

      final bankTx = (results[1] as List<Map<String, dynamic>>)
          .map<TxRowData>(_txFromBank)
          .toList();

      final deposits = (results[2] as List<Map<String, dynamic>>)
          .map<TxRowData>(_txFromDeposit)
          .toList();

      final merged = <TxRowData>[...transfers, ...bankTx, ...deposits]
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      setState(() {
        _items = merged;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Failed to load transactions';
      });
    }
  }

  // ---- mappers ----
  TxRowData _txFromTransfer(Map<String, dynamic> m) {
    final to = (m['toAddress'] ?? '').toString();
    final net = (m['network'] ?? '').toString().toUpperCase();
    final amount = _toDouble(m['amount']);
    final dt = _dt(m['createdAt']);
    return TxRowData(
      // reuse "hash" field as a compact label
      hash: 'Send • ${_short(to)} • $net',
      isSent: true,
      amount: '- ${_fmt2(amount)} ${(m['tokenSymbol'] ?? 'USDT').toString()}',
      date: _fmtDate(dt),
      createdAt: dt,
    );
  }

  TxRowData _txFromBank(Map<String, dynamic> m) {
    final bank = (m['bankCode'] ?? '').toString();
    final amount = _toDouble(m['amountUsdt']);
    final dt = _dt(m['createdAt']);
    return TxRowData(
      hash: 'Bank • $bank',
      isSent: true,
      amount: '- ${_fmt2(amount)} ${(m['tokenSymbol'] ?? 'USDT').toString()}',
      date: _fmtDate(dt),
      createdAt: dt,
    );
  }

  TxRowData _txFromDeposit(Map<String, dynamic> m) {
    final addr = (m['address'] ?? '').toString();
    final net = (m['network'] ?? '').toString().toUpperCase();
    final amount = _toDouble(m['amount']);
    final dt = _dt(m['createdAt']);
    return TxRowData(
      hash: 'Deposit • ${_short(addr)} • $net',
      isSent: false,
      amount: '+ ${_fmt2(amount)} ${(m['tokenSymbol'] ?? 'USDT').toString()}',
      date: _fmtDate(dt),
      createdAt: dt,
    );
  }

  // ---- helpers ----
  double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }
  DateTime _dt(dynamic v) {
    if (v is String) {
      try { return DateTime.parse(v).toLocal(); } catch (_) {}
    }
    return DateTime.now();
  }
  String _short(String a) {
    if (a.isEmpty) return '—';
    if (a.length <= 10) return a;
    return '${a.substring(0, 6)}…${a.substring(a.length - 4)}';
  }
  String _fmt2(double v) {
    final s = v.toStringAsFixed(2);
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
  String _fmtDate(DateTime d) {
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    final mm = months[d.month - 1];
    final dd = d.day.toString().padLeft(1, '0');
    final yyyy = d.year.toString();
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '$mm $dd, $yyyy  $hh:$mi';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : RefreshIndicator(
        onRefresh: _load,
        child: _items.isEmpty
            ? ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            Center(child: Text('No transactions yet')),
          ],
        )
            : ListView.separated(
          padding: const EdgeInsets.all(16),
          itemBuilder: (_, i) => _TxRow(_items[i]),
          separatorBuilder: (_, __) => const Divider(color: Colors.white12),
          itemCount: _items.length,
        ),
      ),
    );
  }
}

class TxRowData {
  final String hash;     // shown as label
  final bool isSent;     // outgoing?
  final String amount;   // formatted with +/- and token
  final String date;     // display string
  final DateTime createdAt;
  TxRowData({
    required this.hash,
    required this.isSent,
    required this.amount,
    required this.date,
    required this.createdAt,
  });
}

class _TxRow extends StatelessWidget {
  final TxRowData d;
  const _TxRow(this.d);

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Container(
        height: 42, width: 42,
        decoration: BoxDecoration(
          color: (d.isSent ? AppColors.danger : AppColors.accent).withValues(alpha: .18),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(d.isSent ? Icons.north_east_rounded : Icons.south_west_rounded),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(d.hash, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(d.date, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ]),
      ),
      Text(
        d.amount,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: d.isSent ? AppColors.danger : AppColors.accent,
        ),
      )
    ]);
  }
}
