import 'package:flutter/widgets.dart';
import 'features/referrals/services/referral_service.dart';
import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ReferralService.instance.captureFromBaseIfWeb();
  runApp(const CryptoWalletApp());
}
