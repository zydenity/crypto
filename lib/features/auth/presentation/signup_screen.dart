import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';
import '../services/auth_service.dart';
import '../../referrals/services/referral_service.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _form = GlobalKey<FormState>();
  final _nameCtrl  = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passCtrl  = TextEditingController();
  bool _obscure = true;
  bool _loading = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  String? _validateEmail(String? v) {
    final value = v?.trim() ?? '';
    if (value.isEmpty) return 'Email is required';
    final emailRe = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
    if (!emailRe.hasMatch(value)) return 'Enter a valid email';
    return null;
  }

  Future<void> _signup() async {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _loading = true);

    final email = _emailCtrl.text.trim();

    try {
      final pendingRef = await ReferralService.instance.getPendingRefCode();

      final assigned = await AuthService.instance.register(
        name: _nameCtrl.text.trim(),
        identifier: email,
        password: _passCtrl.text,
        referralCode: pendingRef,
      );

      await ReferralService.instance.clearPendingRefCode();
      final refCode = await ReferralService.instance.ensureCreatedAfterSignup();

      if (!mounted) return;

      // Optional toasts (they may not show if you immediately navigate)
      if (assigned != null && assigned.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Wallet assigned: ${assigned.substring(0,6)}…${assigned.substring(assigned.length-4)}')),
        );
      }
      if (refCode != null && refCode.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Referral code created: $refCode')),
        );
      }

      // Decide where to go based on whether we already have a session
      if (AuthService.instance.isLoggedIn) {
        // Old flow: server returned token -> go home
        Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
      } else {
        // New flow: email verification required -> go to verify notice
        Navigator.of(context).pushReplacementNamed('/verify', arguments: email);
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      final friendly = (msg.contains('IDENTIFIER_TAKEN') || msg.contains('409'))
          ? 'Email already in use'
          : 'Sign up failed: $e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendly)));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(title: const Text('Create account')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Let’s get you started',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const SizedBox(height: 20),

                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.username, AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    hintText: 'you@domain.com',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator: _validateEmail,
                ),
                const SizedBox(height: 12),

                TextFormField(
                  controller: _passCtrl,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _obscure = !_obscure),
                      icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    ),
                  ),
                  validator: (v) => (v == null || v.length < 6) ? 'Min 6 characters' : null,
                ),
                const SizedBox(height: 20),

                FilledButton(
                  onPressed: _loading ? null : _signup,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: AppColors.accent,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  child: _loading ? const CircularProgressIndicator() : const Text('Create account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
