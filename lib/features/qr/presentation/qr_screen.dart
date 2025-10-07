import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../services/api/wallet_api.dart'; // ← add

class QRScreen extends StatelessWidget {
  const QRScreen({super.key, this.address});
  final String? address; // optional override

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My QR')),
      body: Center(
        child: FutureBuilder<String?>(
          future: address != null
              ? Future.value(address)
              : WalletApi.instance.getDefaultAddress(),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const CircularProgressIndicator();
            }
            final addr = (snap.data ?? '').trim();
            if (addr.isEmpty) {
              return const Text('No wallet address set.');
            }
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                QrImageView(data: addr, size: 220, backgroundColor: Colors.white),
                const SizedBox(height: 14),
                SelectableText(
                  addr,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: addr));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Address copied')),
                      );
                    }
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copy'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
