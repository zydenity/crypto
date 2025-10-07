import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final demo = List.generate(
      8,
          (i) => TxRowData(
        hash: '0x${'a' * 6}$i...${'b' * 4}',
        isSent: i.isOdd,
        amount: i.isOdd ? '-0.0231 ETH' : '+0.5000 ETH',
        date: 'Sep ${12 + i}, 2025',
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemBuilder: (_, i) => _TxRow(demo[i]),
        separatorBuilder: (_, __) => const Divider(color: Colors.white12),
        itemCount: demo.length,
      ),
    );
  }
}

class TxRowData {
  final String hash;
  final bool isSent;
  final String amount;
  final String date;
  TxRowData({required this.hash, required this.isSent, required this.amount, required this.date});
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
          Text(d.hash, style: const TextStyle(fontWeight: FontWeight.w700)),
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
