// lib/features/referrals/services/referral_service.dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import '../../../services/api/wallet_api.dart';

class ReferralService {
  ReferralService._();
  static final ReferralService instance = ReferralService._();

  static const _kPendingRefKey = 'pending_ref_code';

  // Extract code from ?ref=... OR /r/<code>
  String? _extract(Uri uri) {
    final qp = uri.queryParameters['ref'];
    if (qp != null && qp.trim().isNotEmpty) {
      return qp.trim().toUpperCase();
    }
    final segs = uri.pathSegments;
    final i = segs.indexOf('r');
    if (i >= 0 && i + 1 < segs.length) {
      final code = segs[i + 1].trim();
      if (code.isNotEmpty) return code.toUpperCase();
    }
    return null;
  }

  /// Capture from any incoming URI
  Future<void> captureFromUri(Uri uri) async {
    final code = _extract(uri);
    if (code == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPendingRefKey, code);
  }

  /// For Flutter web, read Uri.base on startup
  Future<void> captureFromBaseIfWeb() async {
    if (kIsWeb) {
      await captureFromUri(Uri.base);
    }
  }

  Future<String?> getPendingRefCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kPendingRefKey);
  }

  Future<void> clearPendingRefCode() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kPendingRefKey);
  }

  /// Ensure the logged-in user **has** a referral code; return it.
  /// - If `/referrals/me` already has a code, return it.
  /// - Otherwise, ask server to create one (optionally with a preferred code).
  Future<String?> ensureCreatedAfterSignup({String? prefer}) async {
    try {
      final summary = await WalletApi.instance.getReferralSummary();
      final existing = (summary['code'] as String?)?.trim();
      if (existing != null && existing.isNotEmpty) return existing;

      final created = await WalletApi.instance.createReferralCode(code: prefer ?? '');
      final c1 = created['code'] as String?;
      final c2 = (created['data'] is Map) ? (created['data']['code'] as String?) : null;
      return (c1 ?? c2)?.trim();
    } catch (_) {
      return null; // don’t block signup UX if this fails
    }
  }
}
