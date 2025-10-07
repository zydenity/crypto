import 'package:flutter/material.dart';

class PromoCarousel extends StatelessWidget {
  final List<PromoCardData> items;
  const PromoCarousel({super.key, required this.items});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 170,
      child: PageView(
        controller: PageController(viewportFraction: 0.88),
        children: items.map((e) => _PromoCard(data: e)).toList(),
      ),
    );
  }
}

class PromoCardData {
  final String title;
  final String subtitle;
  const PromoCardData(this.title, this.subtitle);
}

class _PromoCard extends StatelessWidget {
  final PromoCardData data;
  const _PromoCard({required this.data});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(right: 12),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: [Color(0xFF1C2240), Color(0xFF12182F)],
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(data.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(data.subtitle, style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Row(children: const [
            Icon(Icons.info_outline_rounded, size: 16, color: Colors.white70),
            SizedBox(width: 8),
            Text('Learn more', style: TextStyle(color: Color(0xFF24D6A5), fontWeight: FontWeight.w700)),
          ])
        ]),
      ),
    );
  }
}
