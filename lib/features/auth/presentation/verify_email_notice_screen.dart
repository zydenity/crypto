import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';
import '../services/auth_service.dart';

class VerifyEmailNoticeScreen extends StatefulWidget {
  final String email;
  final String? password; // optional convenience
  const VerifyEmailNoticeScreen({super.key, required this.email, this.password});

  @override
  State<VerifyEmailNoticeScreen> createState() => _VerifyEmailNoticeScreenState();
}

class _VerifyEmailNoticeScreenState extends State<VerifyEmailNoticeScreen> {
  bool _busy = false;
  Timer? _poller; // optional auto-check (every 8s)

  @override
  void initState() {
    super.initState();
    // Optional: background polling to detect verification without tapping a button
    _poller = Timer.periodic(const Duration(seconds: 8), (_) => _tryAutoLogin());
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  Future<void> _resend() async {
    setState(() => _busy = true);
    try {
      await AuthService.instance.resendVerification(email: widget.email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verification link sent. Check your inbox (and spam).')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Resend failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tryAutoLogin() async {
    if (!mounted || _busy) return;
    try {
      final ok = await AuthService.instance.checkVerified(widget.email);
      if (!ok) return;

      // If verified, attempt login (only if we have the password)
      if (widget.password != null && widget.password!.isNotEmpty) {
        setState(() => _busy = true);
        final success = await AuthService.instance.login(
          identifier: widget.email,
          password: widget.password!,
        );
        if (!mounted) return;

        if (success) {
          // (Optional) clear the local copy of password by replacing the route
          Navigator.of(context).pushNamedAndRemoveUntil('/home', (r) => false);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Verified. Please sign in again.')),
          );
          Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
        }
      } else {
        // Verified but no password available—return to login
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Email verified. Please sign in.')),
        );
        if (!mounted) return;
        Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);
      }
    } catch (_) {
      // ignore poll errors
    } finally {
      if (mounted) setState(() {}); // refresh any loading state if needed
    }
  }

  Future<void> _iveVerified() async {
    setState(() => _busy = true);
    try {
      final ok = await AuthService.instance.checkVerified(widget.email);
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not verified yet. Please tap the link in your email.')),
        );
        return;
      }

      if (widget.password != null && widget.password!.isNotEmpty) {
        final success = await AuthService.instance.login(
          identifier: widget.email,
          password: widget.password!,
        );
        if (success) {
          Navigator.of(context).pushNamedAndRemoveUntil('/home', (r) => false);
          return;
        }
      }

      // Fallback: go back to login
      Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false);

    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Check failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Verify your email')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('We sent a verification link to:', style: TextStyle(color: AppColors.subtle)),
            const SizedBox(height: 6),
            Text(widget.email, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            const SizedBox(height: 16),
            Text(
              'Open your inbox and tap the link to verify. Once done, tap the button below to continue.',
              style: TextStyle(color: AppColors.subtle),
            ),
            const Spacer(),
            FilledButton(
              onPressed: _busy ? null : _resend,
              child: _busy
                  ? const CircularProgressIndicator()
                  : const Text('Resend verification email'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : _iveVerified,
              child: const Text("I've verified — Sign in"),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pushNamedAndRemoveUntil('/', (r) => false),
              child: const Text('Back to Login'),
            ),
          ],
        ),
      ),
    );
  }
}
