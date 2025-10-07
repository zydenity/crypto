import 'package:flutter/material.dart';

class ExploreItem { final String label; final IconData icon; const ExploreItem(this.label, this.icon); }



class _ExplorePill extends StatelessWidget {
  final ExploreItem i;
  const _ExplorePill({required this.i});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(children: [
        Icon(i.icon, size: 16),
        const SizedBox(width: 8),
        Text(i.label, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
