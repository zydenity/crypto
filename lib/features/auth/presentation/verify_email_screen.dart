// lib/features/auth/presentation/verify_email_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';
import '../services/auth_service.dart';

class VerifyEmailScreen extends StatefulWidget {
  /// If you navigate with: Navigator.pushNamed('/verify', arguments: email),
  /// you can leave this null – the screen will read it from route arguments.
  final String? email;

  const VerifyEmailScreen({super.key, this.email});

  @override
  State<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends State<VerifyEmailScreen> {
  String? _email;
  Timer? _pollTimer;
  Timer? _cooldownTimer;
  bool _sending = false;
  int _cooldown = 0; // seconds

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_email != null) return; // already initialized

    // Prefer constructor arg; else read from route arguments
    final arg = ModalRoute.of(context)?.settings.arguments;
    _email = widget.email ?? (arg is String ? arg : null);

    // Start polling once we have the email
    if (_email != null) _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        final ok = await AuthService.instance.checkVerified(_email!);
        if (!mounted) return;
        if (ok) {
          _pollTimer?.cancel();
          if (!mounted) return;
          // Go to login (clear history)
          Navigator.of(context).pushNamedAndRemoveUntil('/login', (r) => false);
        }
      } catch (_) {
        // Ignore transient errors while polling
      }
    });
  }

  Future<void> _resend() async {
    if (_email == null || _cooldown > 0) return;
    setState(() {
      _sending = true;
    });
    try {
      await AuthService.instance.resendVerification(email: _email!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification email sent')),
      );
      // Start a 30s cooldown to avoid spam
      setState(() => _cooldown = 30);
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) return;
        if (_cooldown <= 1) {
          t.cancel();
          setState(() => _cooldown = 0);
        } else {
          setState(() => _cooldown -= 1);
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to resend: $e')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final email = _email;

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('Verify your email'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('We sent a verification link to',
                style: TextStyle(color: AppColors.subtle)),
            const SizedBox(height: 6),
            Text(
              email ?? '—',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            const Text(
              'Open the link in your email to activate your account. '
                  'Didn’t get it? Check spam or resend.',
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed:
                (_sending || _cooldown > 0 || email == null) ? null : _resend,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: AppColors.accent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _sending
                    ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : Text(
                  _cooldown > 0 ? 'Resend in $_cooldown s' : 'Resend email',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
