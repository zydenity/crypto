import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/app_colors.dart';
import '../../../services/api/wallet_api.dart';

class ReceiveFundsScreen extends StatefulWidget {
  const ReceiveFundsScreen({
    super.key,
    this.address, // optional; will fetch from API if null
    this.tokenSymbol = 'USDT',
    this.network = 'Ethereum',
    this.tokenIconAsset = 'assets/icons/usdt.svg',
    this.erc20Contract = '0xdAC17F958D2ee523a2206206994597C13D831ec7',
    this.decimals = 6,
  });

  final String? address;
  final String tokenSymbol;
  final String network;
  final String tokenIconAsset;
  final String erc20Contract;
  final int decimals;

  @override
  State<ReceiveFundsScreen> createState() => _ReceiveFundsScreenState();
}

class _ReceiveFundsScreenState extends State<ReceiveFundsScreen> {
  String? _address;            // resolved address
  String _qrData = '';         // address or EIP-681 payload
  double? _requestedAmount;
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _deposits = [];
  bool _loadingDeposits = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final a = widget.address ?? await WalletApi.instance.getDefaultAddress();
      if (!mounted) return;
      if (a == null || a.isEmpty) {
        setState(() { _loading = false; _error = 'No default wallet set.'; });
        return;
      }
      setState(() {
        _address = a;
        _qrData = a;     // default QR is just the address
        _loading = false;
      });
      _loadDeposits();
    } catch (_) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Failed to load wallet address.'; });
    }
  }

  Future<void> _loadDeposits() async {
    final addr = _address;
    if (addr == null) return;
    setState(() => _loadingDeposits = true);
    try {
      final list = await WalletApi.instance.listDeposits(address: addr);

      if (!mounted) return;
      setState(() {
        _deposits = list;
      });
    } finally {
      if (mounted) setState(() => _loadingDeposits = false);
    }
  }

  String _erc20Eip681(String address, double amount) {
    final units = (amount * math.pow(10, widget.decimals)).round();
    return 'ethereum:${widget.erc20Contract}/transfer?address=$address&uint256=$units';
  }

  Future<void> _setAmount() async {
    final addr = _address;
    if (addr == null) return;

    final controller = TextEditingController(text: _requestedAmount?.toString() ?? '');
    final amount = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16, right: 16, top: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Set amount (${widget.tokenSymbol})',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  hintText: 'e.g. 25.00',
                  prefixIcon: Icon(Icons.attach_money_rounded),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () {
                      final v = double.tryParse(controller.text.trim());
                      Navigator.of(ctx).pop(v);
                    },
                    child: const Text('Apply'),
                  ),
                ),
              ]),
            ],
          ),
        );
      },
    );

    if (amount != null && amount > 0) {
      setState(() {
        _requestedAmount = amount;
        _qrData = _erc20Eip681(addr, amount);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Amount set to $amount ${widget.tokenSymbol}')),
      );
    }
  }

  Future<void> _copyAddress() async {
    final addr = _address;
    if (addr == null) return;
    await Clipboard.setData(ClipboardData(text: addr));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Address copied')),
    );
  }

  // Upload proof of deposit and record in DB
  Future<void> _openUploadProof() async {
    final addr = _address;
    if (addr == null || addr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No address available')),
      );
      return;
    }

    double? amount;
    String source = 'Binance';
    String? txHash;
    Uint8List? pickedBytes;
    String? fileName;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final amountCtrl = TextEditingController();
        final txCtrl = TextEditingController();
        return StatefulBuilder(builder: (ctx, setM) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16, right: 16, top: 16,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Record deposit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 12),

                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Amount (USDT)',
                    prefixIcon: Icon(Icons.attach_money_rounded),
                  ),
                ),
                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  value: source,
                  items: const [
                    DropdownMenuItem(value: 'Binance', child: Text('Binance')),
                    DropdownMenuItem(value: 'OKX', child: Text('OKX')),
                    DropdownMenuItem(value: 'Bybit', child: Text('Bybit')),
                    DropdownMenuItem(value: 'Coinbase', child: Text('Coinbase')),
                    DropdownMenuItem(value: 'Wallet', child: Text('Another Wallet')),
                    DropdownMenuItem(value: 'Other', child: Text('Other')),
                  ],
                  onChanged: (v) => setM(() => source = v ?? 'Binance'),
                  decoration: const InputDecoration(labelText: 'Source'),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: txCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Tx hash (optional)',
                    prefixIcon: Icon(Icons.link_rounded),
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    FilledButton.tonal(
                      onPressed: () async {
                        final res = await FilePicker.platform.pickFiles(
                          type: FileType.image,
                          withData: true,
                        );
                        if (res != null && res.files.single.bytes != null) {
                          setM(() {
                            pickedBytes = res.files.single.bytes!;
                            fileName = res.files.single.name;
                          });
                        }
                      },
                      child: const Text('Choose image'),
                    ),
                    const SizedBox(width: 12),
                    if (pickedBytes != null)
                      const Icon(Icons.check_circle, color: Colors.green),
                  ],
                ),
                const SizedBox(height: 12),

                Row(children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        amount = double.tryParse(amountCtrl.text.trim());
                        txHash = txCtrl.text.trim().isEmpty ? null : txCtrl.text.trim();
                        if (amount == null || amount! <= 0) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Enter a valid amount')),
                          );
                          return;
                        }
                        if (pickedBytes == null || fileName == null) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('Attach a proof image')),
                          );
                          return;
                        }
                        Navigator.pop(ctx, true);
                      },
                      child: const Text('Submit'),
                    ),
                  ),
                ]),
              ],
            ),
          );
        });
      },
    );

    if (!mounted) return;
    if (amount != null && pickedBytes != null && fileName != null) {
      try {
        final result = await WalletApi.instance.uploadDepositProof(
          address: addr,
          amount: amount!,
          source: source,
          bytes: pickedBytes!,
          filename: fileName!,
          tokenSymbol: widget.tokenSymbol,
          network: widget.network.toLowerCase(),
          txHash: txHash,
        );
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deposit recorded: ${result['deposit']['amount']} ${result['deposit']['tokenSymbol']}')),
        );
        _loadDeposits(); // refresh list
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  Color _statusColor(String s) {
    switch (s.toLowerCase()) {
      case 'verified': return const Color(0xFF20C997);
      case 'rejected': return const Color(0xFFE03131);
      default: return const Color(0xFFFFC107); // pending
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(appBar: AppBar(title: const Text('Receive')),
          body: Center(child: Text(_error!)));
    }

    final addr = _address!; // safe now
    final chipColor = AppColors.card;

    return Scaffold(
      appBar: AppBar(title: const Text('Receive')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // warning
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF7A5D19).withValues(alpha: .25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFB68B2A).withValues(alpha: .35)),
            ),
            child: Text(
              'Only send ${widget.tokenSymbol} (ERC-20) on ${widget.network} to this address. '
                  'Other assets or networks may be lost.',
              style: const TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),

          Row(children: [
            _chipWithIcon(widget.tokenIconAsset, widget.tokenSymbol, chipColor),
            const SizedBox(width: 8),
            _chipText(widget.network, chipColor),
          ]),
          const SizedBox(height: 16),

          // QR + address
          Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
            padding: const EdgeInsets.all(14),
            child: Column(children: [
              QrImageView(data: _qrData, size: 260, backgroundColor: Colors.white),
              const SizedBox(height: 8),
              Text(addr, textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black87, fontSize: 12)),
            ]),
          ),
          const SizedBox(height: 16),

          // actions
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _ActionButton(icon: Icons.copy_rounded, label: 'Copy', onTap: _copyAddress),
              _ActionButton(icon: Icons.tag_rounded, label: 'Set Amount', onTap: _setAmount),
              _ActionButton(icon: Icons.cloud_upload_outlined, label: 'Upload Proof', onTap: _openUploadProof),
            ],
          ),

          if (_requestedAmount != null) ...[
            const SizedBox(height: 16),
            Text('Requesting: ${_requestedAmount!.toStringAsFixed(2)} ${widget.tokenSymbol}',
                textAlign: TextAlign.center, style: TextStyle(color: AppColors.subtle)),
          ],

          const SizedBox(height: 24),

          // Recent deposits
          Row(
            children: [
              const Text('Recent Deposits', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _loadingDeposits ? null : _loadDeposits,
                tooltip: 'Refresh',
              ),
            ],
          ),
          const SizedBox(height: 8),

          if (_loadingDeposits)
            const Center(child: Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            ))
          else if (_deposits.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No deposits yet for this address.',
                  style: TextStyle(color: AppColors.subtle)),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _deposits.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final d = _deposits[i];
                final status = (d['status'] ?? 'pending').toString();
                final amount = (d['amount'] ?? 0).toString();
                final source = (d['source'] ?? '—').toString();
                final when = (d['createdAt'] ?? '').toString();
                final imageUrl = (d['imageUrl'] ?? '').toString();
                return Container(
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (imageUrl.isNotEmpty)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(imageUrl, width: 48, height: 48, fit: BoxFit.cover),
                        )
                      else
                        const Icon(Icons.receipt_long_rounded, size: 36),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('$amount ${widget.tokenSymbol}',
                                style: const TextStyle(fontWeight: FontWeight.w700)),
                            const SizedBox(height: 2),
                            Text('Source: $source • $when',
                                style: TextStyle(color: AppColors.subtle, fontSize: 12)),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _statusColor(status).withValues(alpha: .15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _statusColor(status).withValues(alpha: .5)),
                        ),
                        child: Text(status[0].toUpperCase() + status.substring(1),
                            style: TextStyle(
                              color: _statusColor(status),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            )),
                      ),
                    ],
                  ),
                );
              },
            ),

          const SizedBox(height: 16),
          // deposit hint footer
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(12)),
            child: Row(children: const [
              Icon(Icons.south_rounded, size: 24),
              SizedBox(width: 12),
              Expanded(child: Text('Deposit from exchange\nBy direct transfer from your account',
                  style: TextStyle(height: 1.3))),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _chipWithIcon(String asset, String label, Color chipColor) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: chipColor, borderRadius: BorderRadius.circular(20)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Container(
        width: 18, height: 18,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
        padding: const EdgeInsets.all(2.5),
        child: SvgPicture.asset(asset),
      ),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ]),
  );

  Widget _chipText(String label, Color chipColor) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(color: chipColor, borderRadius: BorderRadius.circular(20)),
    child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
  );
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Ink(
        decoration: BoxDecoration(color: AppColors.card, shape: BoxShape.circle),
        child: IconButton(icon: Icon(icon), onPressed: onTap),
      ),
      const SizedBox(height: 6),
      Text(label),
    ]);
  }
}
