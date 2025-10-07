import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../core/app_colors.dart';

class BalanceCard extends StatelessWidget {
  final String balanceText;              // e.g. "USDT 123.4567"
  final String subtitle;                 // e.g. "0xABCD…1234"
  final VoidCallback onPrimary;          // "+ Add Funds" action
  final String primaryLabel;             // button label
  final String tokenIconAsset;           // e.g. assets/icons/usdt.svg
  final String headerLabel;              // e.g. "USDT  •  AVAILABLE BALANCE"
  final bool showEye;                    // show eye icon or not

  const BalanceCard({
    super.key,
    required this.balanceText,
    required this.subtitle,
    required this.onPrimary,
    this.primaryLabel = '+ Add Funds',
    this.tokenIconAsset = 'assets/icons/usdt.svg',
    this.headerLabel = 'USDT  •  AVAILABLE BALANCE',
    this.showEye = true,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.gradientTop, AppColors.gradientBottom],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.25),
            blurRadius: 18,
            spreadRadius: -8,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: token chip + label
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                padding: const EdgeInsets.all(2.5),
                child: SvgPicture.asset(tokenIconAsset, fit: BoxFit.contain),
              ),
              const SizedBox(width: 8),
              Text(
                headerLabel,
                style: TextStyle(
                  color: AppColors.subtle.withValues(alpha: 0.9),
                  fontSize: 12,
                  letterSpacing: .6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Balance + (optional) eye + CTA
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
// NEW – show the exact amount, no "..."
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    balanceText,
                    maxLines: 1,
                    softWrap: false, // no wrapping
                    // no overflow: ellipsis
                    style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
                  ),
                ),
              ),

              if (showEye) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.visibility_outlined,
                  color: AppColors.subtle.withValues(alpha: 0.9),
                  size: 18,
                ),
              ],
              const Spacer(),
              FilledButton(
                onPressed: onPrimary,
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(primaryLabel),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Footer
          Text(
            subtitle,
            style: const TextStyle(color: AppColors.subtle, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
