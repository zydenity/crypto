import 'package:flutter/material.dart';
import '../../../core/app_colors.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _busy = false;

  Future<void> _logout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out?'),
        content: const Text('You’ll need to log in again to access your wallet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _busy = true);
    try {
      // Firebase sign-out (safe to call even if no user is signed in)


      // TODO: If you store API/JWT tokens locally, clear them here
      // e.g. await SecureStorage().delete(key: 'auth_token');

      if (!mounted) return;
      // Navigate to your login screen; change route name as needed
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (route) => false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: const Text('Niño Apostol'),
                subtitle: Text('Web3 Ready', style: TextStyle(color: AppColors.subtle)),
                trailing: const Icon(Icons.edit),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(children: const [
                  _ProfileTile(icon: Icons.security_rounded, title: 'Security', subtitle: 'Biometrics, passcode'),
                  Divider(height: 1, color: Colors.white12),
                  _ProfileTile(icon: Icons.settings_rounded, title: 'Settings', subtitle: 'Currency, networks'),
                  Divider(height: 1, color: Colors.white12),
                  _ProfileTile(icon: Icons.help_outline_rounded, title: 'Help & Support', subtitle: 'Docs & chat'),
                ]),
              ),
              const SizedBox(height: 16),
              Card(
                child: ListTile(
                  leading: const Icon(Icons.logout_rounded, color: Colors.redAccent),
                  title: const Text('Log out', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.redAccent)),
                  subtitle: Text('Sign out of this device', style: TextStyle(color: AppColors.subtle)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.redAccent),
                  onTap: _logout,
                ),
              ),
            ],
          ),
          if (_busy)
            const LinearProgressIndicator(minHeight: 2),
        ],
      ),
    );
  }
}

class _ProfileTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _ProfileTile({required this.icon, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, style: TextStyle(color: AppColors.subtle)),
      trailing: const Icon(Icons.chevron_right_rounded),
    );
  }
}
