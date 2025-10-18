import 'package:flutter/material.dart';
import '../core/app_theme.dart';

// alias your screens (use a different prefix to avoid clashing with the service)
import '../features/auth/presentation/login_screen.dart' as authui;
import '../features/inbox/presentation/inbox_screen.dart' as inbox;
import '../features/qr/presentation/qr_screen.dart' as qr;
import '../features/transactions/presentation/transactions_screen.dart' as tx;
import '../features/profile/presentation/profile_screen.dart' as profile;
import '../features/wallet/presentation/wallet_screen.dart' as wallet;
import '../features/auth/presentation/verify_email_notice_screen.dart';
// auth service with its own prefix
import '../features/auth/services/auth_service.dart' as auth;

class CryptoWalletApp extends StatelessWidget {
  const CryptoWalletApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crypto Wallet',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const _Bootstrap(),
      routes: {
        '/login': (_) => const authui.LoginScreen(),
        '/home' : (_) => const _HomeShell(),
        '/verify': (ctx) {
          final email = ModalRoute.of(ctx)!.settings.arguments as String;
          return VerifyEmailNoticeScreen(email: email);
        },
      },
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap({super.key});
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  @override
  void initState() {
    super.initState();
    _decide();
  }

  Future<void> _decide() async {
    await auth.AuthService.instance.init(); // load stored JWT
    if (!mounted) return;
    final hasToken = auth.AuthService.instance.token?.isNotEmpty == true;
    Navigator.of(context).pushReplacementNamed(hasToken ? '/home' : '/login');
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _HomeShell extends StatefulWidget {
  const _HomeShell({super.key});
  @override
  State<_HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<_HomeShell> {
  int current = 0;

  final pages = <Widget>[
    const wallet.WalletScreen(),
    const inbox.InboxScreen(),
    const qr.QRScreen(),
    const tx.TransactionsScreen(),
    const profile.ProfileScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: pages[current],
      bottomNavigationBar: NavigationBar(
        backgroundColor: Theme.of(context).colorScheme.surface,
        indicatorColor:
        Theme.of(context).colorScheme.primary.withValues(alpha: .15),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.mail_outline_rounded), label: 'Inbox'),
          NavigationDestination(icon: Icon(Icons.qr_code_rounded), label: 'QR'),
          NavigationDestination(icon: Icon(Icons.receipt_long_rounded), label: 'Activity'),
          NavigationDestination(icon: Icon(Icons.person_outline_rounded), label: 'Profile'),
        ],
        selectedIndex: current,
        onDestinationSelected: (i) => setState(() => current = i),
      ),
    );
  }
}
