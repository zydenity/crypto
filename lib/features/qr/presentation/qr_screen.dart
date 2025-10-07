import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class QRScreen extends StatelessWidget {
  const QRScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const demoAddress = '0x0000000000000000000000000000000000000000';
    return Scaffold(
      appBar: AppBar(title: const Text('My QR')),
      body: Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          QrImageView(data: demoAddress, size: 220, backgroundColor: Colors.white),
          const SizedBox(height: 14),
          Text(demoAddress, style: const TextStyle(fontSize: 12, color: Colors.white70)),
        ]),
      ),
    );
  }
}
