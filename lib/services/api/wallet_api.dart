// lib/services/api/wallet_api.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../features/auth/services/auth_service.dart';

class WalletApi {
  WalletApi._();
  static final WalletApi instance = WalletApi._();

  /// Build-time override: --dart-define=API_BASE=https://api.yourdomain.com
  static const _apiBaseFromEnv = String.fromEnvironment('API_BASE', defaultValue: '');

  /// Central base URL (no trailing slash); falls back to local dev if not defined.
  String get baseUrl {
    if (_apiBaseFromEnv.isNotEmpty) {
      return _apiBaseFromEnv.endsWith('/')
          ? _apiBaseFromEnv.substring(0, _apiBaseFromEnv.length - 1)
          : _apiBaseFromEnv;
    }
    // Dev fallbacks
    final isAndroidEmu = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return isAndroidEmu ? 'http://10.0.2.2:3000' : 'http://localhost:3000';
  }

  Uri url(String path) => Uri.parse('$baseUrl$path');

  // ------------------------------- headers -----------------------------------
  Map<String, String> _authHeaders() => {
    ...AuthService.instance.authHeaders(),
    'Accept': 'application/json',
  };

  Map<String, String> _jsonHeaders() => {
    ..._authHeaders(),
    'Content-Type': 'application/json',
  };
  Future<Map<String, dynamic>> me() async {
    final r = await _authedGet('/me');                // uses your authed GET
    return Map<String, dynamic>.from(r as Map);       // type-safe cast
  }

  Future<String?> getOwnerName() async {
    try {
      final m = await me();                           // { uid, idf, name }
      final n = (m['name'] ?? m['idf'] ?? '').toString().trim();
      return n.isEmpty ? null : n;
    } catch (_) {
      return null;
    }
  }

  // --------------------------- logging helpers -------------------------------
  String _short(String s) =>
      s.length <= 14 ? s : '${s.substring(0, 6)}…${s.substring(s.length - 4)}';

  Map<String, String> _safeHeaders(Map<String, String> h) {
    final m = Map<String, String>.from(h);
    final auth = m['Authorization'];
    if (auth != null && auth.startsWith('Bearer ')) {
      final token = auth.substring(7);
      m['Authorization'] = 'Bearer ${_short(token)}';
    }
    return m;
  }

  String _nextId() => DateTime.now().microsecondsSinceEpoch.toString();

  void _logReq(String id, String method, Uri url, Map<String, String> headers,
      [Object? body]) {
    if (!kDebugMode) return;
    debugPrint('[API $id] $method $url');
    debugPrint('[API $id] headers=${_safeHeaders(headers)}');
    if (body != null) {
      final s = body is String ? body : jsonEncode(body);
      debugPrint('[API $id] body=${s.length > 800 ? '${s.substring(0, 800)}…(${s.length})' : s}');
    }
  }

  void _logResp(String id, http.Response r, DateTime t0) {
    if (!kDebugMode) return;
    final ms = DateTime.now().difference(t0).inMilliseconds;
    final b = r.body;
    final show = b.length > 800 ? '${b.substring(0, 800)}…(${b.length})' : b;
    debugPrint('[API $id] ← ${r.statusCode} in ${ms}ms');
    debugPrint('[API $id] resp=$show');
  }

  // ------------------------------ http helpers -------------------------------
  Future<http.Response> _authedGetResp(String path) async {
    final id = _nextId();
    final url = Uri.parse('$baseUrl$path');
    final headers = _authHeaders();
    final t0 = DateTime.now();
    _logReq(id, 'GET', url, headers);
    final r = await http.get(url, headers: headers);
    _logResp(id, r, t0);
    return r;
  }

  Future<dynamic> _authedGet(String path) async {
    final r = await _authedGetResp(path);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('GET $path failed: ${r.statusCode} ${r.body}');
    }
    return jsonDecode(r.body);
  }

  Future<http.Response> _authedPostResp(String path, Map<String, dynamic> body) async {
    final id = _nextId();
    final url = Uri.parse('$baseUrl$path');
    final headers = _jsonHeaders();
    final t0 = DateTime.now();
    _logReq(id, 'POST', url, headers, body);
    final r = await http.post(url, headers: headers, body: jsonEncode(body));
    _logResp(id, r, t0);
    return r;
  }

  Future<dynamic> _authedPost(String path, Map<String, dynamic> body) async {
    final r = await _authedPostResp(path, body);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('POST $path failed: ${r.statusCode} ${r.body}');
    }
    return jsonDecode(r.body);
  }

  Future<http.Response> _authedPatchResp(String path, Map<String, dynamic> body) async {
    final id = _nextId();
    final url = Uri.parse('$baseUrl$path');
    final headers = _jsonHeaders();
    final t0 = DateTime.now();
    _logReq(id, 'PATCH', url, headers, body);
    final r = await http.patch(url, headers: headers, body: jsonEncode(body));
    _logResp(id, r, t0);
    return r;
  }

  Future<dynamic> _authedPatch(String path, Map<String, dynamic> body) async {
    final r = await _authedPatchResp(path, body);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('PATCH $path failed: ${r.statusCode} ${r.body}');
    }
    return jsonDecode(r.body);
  }

  // ------------------------- AI Profit (Overall Summary) ---------------------
  Future<Map<String, dynamic>> getAiProfitOverall({String? address}) async {
    final q = (address == null || address.isEmpty) ? '' : '?address=$address';

    // Try preferred then fallback, to stay compatible with older servers.
    final paths = <String>[
      '/ai/profit/summary$q',
      '/ai-profit/summary$q',
    ];

    http.Response? last;
    for (final p in paths) {
      final r = await _authedGetResp(p);
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
      last = r;
      if (r.statusCode == 404) {
        continue; // try next path
      } else {
        throw Exception('GET $p failed: ${r.statusCode} ${r.body}');
      }
    }

    throw Exception('GET ${paths.join(" or ")} failed: '
        '${last?.statusCode ?? "no-response"} ${last?.body ?? ""}');
  }

  Future<Map<String, dynamic>> getAiProfitToday({String? address}) async {
    final q = (address == null || address.isEmpty) ? '' : '?address=$address';
    final uri = Uri.parse('$baseUrl/ai/profit/today$q');
    final r = await http.get(uri, headers: _authHeaders());
    if (r.statusCode != 200) {
      throw Exception('ai/profit/today ${r.statusCode}: ${r.body}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  // ------------------------------- wallets -----------------------------------
  Future<String?> getDefaultAddress() async {
    final r = await _authedGetResp('/wallet/default');
    if (r.statusCode == 200) {
      return (jsonDecode(r.body) as Map<String, dynamic>)['address'] as String?;
    }
    if (r.statusCode == 404) return null;
    throw Exception('GET /wallet/default failed: ${r.statusCode} ${r.body}');
  }

  Future<Map<String, dynamic>?> getDefaultWallet() async {
    final r = await _authedGetResp('/wallet/default');
    if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode == 404) return null;
    throw Exception('GET /wallet/default failed: ${r.statusCode} ${r.body}');
  }

  Future<void> setDefaultAddress(String address, {String label = 'My Wallet'}) async {
    final r = await _authedPostResp('/wallet/default', {'address': address, 'label': label});
    if (r.statusCode >= 400) {
      throw Exception('Failed to set default wallet: ${r.statusCode} ${r.body}');
    }
  }

  Future<List<Map<String, dynamic>>> listWallets() async {
    final r = await _authedGet('/wallets');
    return (r as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> getBalance({
    required String address,
    String tokenSymbol = 'USDT',
    String network = 'ethereum', // or 'tron' / 'bsc' if that’s your default
    bool debug = false,
  }) async {
    final addr = address.toLowerCase().trim();
    final token = tokenSymbol.toUpperCase();
    final net = network.toLowerCase();

    // Try modern then legacy paths
    final paths = <String>[
      '/wallet/balance?address=$addr&token=$token&network=$net${debug ? '&debug=1' : ''}',
      '/balance?address=$addr&token=$token&network=$net${debug ? '&debug=1' : ''}',
      '/balance?address=$addr&tokenSymbol=$token${debug ? '&debug=1' : ''}', // last-resort legacy
    ];

    http.Response? last;
    for (final p in paths) {
      final r = await _authedGetResp(p);
      if (r.statusCode == 200) {
        final raw = jsonDecode(r.body) as Map<String, dynamic>;

        double asD(dynamic v) =>
            v is num ? v.toDouble() : double.tryParse('$v') ?? 0.0;

        // Normalize variants coming from different server versions
        final available = asD(raw['available'] ?? raw['spendable'] ?? raw['verified'] ?? 0);
        final verified  = asD(raw['verified']  ?? raw['confirmed']  ?? available);
        final pending   = asD(raw['pending']   ?? raw['unconfirmed'] ?? 0);

        return {
          'available': available,
          'verified': verified,
          'pending': pending,
        };
      }
      last = r;
      if (r.statusCode == 404) continue;
      throw Exception('GET $p failed: ${r.statusCode} ${r.body}');
    }

    throw Exception('Balance endpoint not found: tried ${paths.join(", ")}'
        '${last != null ? ' (last=${last.statusCode})' : ''}');
  }


  Future<double> getSpendableUsdt({bool debug = false}) async {
    final addr = await getDefaultAddress();
    if (addr == null) throw Exception('NO_DEFAULT_WALLET');
    final bal = await getBalance(address: addr, tokenSymbol: 'USDT', debug: debug);
    return (bal['available'] as num).toDouble(); // <— use available
  }

  Future<Map<String, dynamic>> getDefaultSpendable() async {
    final addr = await getDefaultAddress();
    if (addr == null) throw Exception('NO_DEFAULT_WALLET');
    final bal = await getBalance(address: addr, tokenSymbol: 'USDT');
    return {'address': addr, 'available': (bal['available'] as num).toDouble()};
  }



  // ------------------------------ deposits -----------------------------------
  Future<Map<String, dynamic>> uploadDepositProof({
    required String address,
    required double amount,
    required String source,
    required List<int> bytes,
    required String filename,
    String tokenSymbol = 'USDT',
    String network = 'ethereum',
    String? txHash,
  }) async {
    final uri = Uri.parse('$baseUrl/deposits');
    final headers = _authHeaders();
    if (kDebugMode) {
      debugPrint('[UPLOAD] POST $uri');
      debugPrint('[UPLOAD] headers=${_safeHeaders(headers)}');
      debugPrint(
          '[UPLOAD] fields={address:$address, amount:$amount, tokenSymbol:$tokenSymbol, network:$network, source:$source, txHash:${txHash ?? ""}}');
    }
    final req = http.MultipartRequest('POST', uri)
      ..headers.addAll(headers)
      ..fields['address'] = address
      ..fields['amount'] = amount.toString()
      ..fields['tokenSymbol'] = tokenSymbol
      ..fields['network'] = network
      ..fields['source'] = source;
    if (txHash != null && txHash.isNotEmpty) req.fields['txHash'] = txHash;
    req.files.add(http.MultipartFile.fromBytes('proof', bytes, filename: filename));

    final t0 = DateTime.now();
    final resp = await req.send();
    final body = await resp.stream.bytesToString();
    if (kDebugMode) {
      final ms = DateTime.now().difference(t0).inMilliseconds;
      final show = body.length > 800 ? '${body.substring(0, 800)}…(${body.length})' : body;
      debugPrint('[UPLOAD] ← ${resp.statusCode} in ${ms}ms');
      debugPrint('[UPLOAD] resp=$show');
    }
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw Exception('Upload failed: ${resp.statusCode} $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listDeposits({String? address}) async {
    final path = '/deposits${address == null ? '' : '?address=$address'}';
    final r = await _authedGet(path);
    return (r as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // ------------------------------ transfers -----------------------------------
  Future<Map<String, dynamic>> createTransfer({
    required String fromAddress,
    required String toAddress,
    required double amount,
    String? note,
    String tokenSymbol = 'USDT',
    String network = 'ethereum',
  }) async {
    final r = await _authedPost('/transfers', {
      'fromAddress': fromAddress,
      'toAddress': toAddress,
      'amount': amount,
      'tokenSymbol': tokenSymbol,
      'network': network,
      if (note != null && note.isNotEmpty) 'note': note,
    });
    return r as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listTransfers() async {
    final r = await _authedGet('/transfers');
    return (r as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // --------------------------- bank transfers ---------------------------------
  Future<List<Map<String, dynamic>>> listBankTransfers() async {
    final r = await _authedGet('/bank-transfers');
    return (r as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<List<Map<String, dynamic>>> listBanks() async {
    final r = await _authedGet('/banks');
    return (r as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<double> getUsdtPhpRate() async {
    final j = await _authedGet('/rates/usdt-php') as Map<String, dynamic>;
    return (j['rate'] as num).toDouble();
  }

  Future<Map<String, dynamic>> createBankTransfer({
    required String fromAddress,
    required String bankCode,
    required String accountNumber,
    required String accountName,
    required double amountUsdt,
    double? rateUsdtPhp, // optional override
    String? note,
  }) async {
    final r = await _authedPost('/bank-transfers', {
      'fromAddress': fromAddress,
      'bankCode': bankCode,
      'accountNumber': accountNumber,
      'accountName': accountName,
      'amountUsdt': amountUsdt,
      'rate': rateUsdtPhp,
      'note': note,
    });
    return r as Map<String, dynamic>;
  }

  // ------------------------------ market --------------------------------------
  Future<List<Map<String, dynamic>>> listMarketCoins({String? query}) async {
    final q = (query != null && query.isNotEmpty) ? '?q=${Uri.encodeComponent(query)}' : '';
    final uri = Uri.parse('$baseUrl/market/coins$q');
    final r = await http.get(uri, headers: _authHeaders());
    debugPrint('GET ${uri.path}${uri.query.isNotEmpty ? '?'+uri.query : ''} -> ${r.statusCode}');
    if (r.statusCode != 200) {
      throw Exception('Market error: ${r.statusCode} ${r.body}');
    }
    final arr = jsonDecode(r.body) as List;
    return arr
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  // ------------------------- AI Subscriptions ---------------------------------
  Future<List<Map<String, dynamic>>> listAiSubscriptions({String? address}) async {
    final path = address == null ? '/ai/subscriptions' : '/ai/subscriptions?address=$address';
    final resp = await _authedGetResp(path);
    if (resp.statusCode == 404) return []; // tolerate old server
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('GET $path failed: ${resp.statusCode} ${resp.body}');
    }
    final body = jsonDecode(resp.body) as List;
    return body
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> upsertAiSubscription({
    required String fromAddress,
    required String symbol,
    required double amountUsdt,
    String tokenSymbol = 'USDT',
    int? contractDays,
  }) async {
    final payload = {
      'fromAddress': fromAddress,
      'symbol': symbol.toUpperCase(),
      'amountUsdt': amountUsdt,
      'tokenSymbol': tokenSymbol.toUpperCase(),
      if (contractDays != null) 'contractDays': contractDays,
    };
    final r = await _authedPost('/ai/subscriptions', payload);
    return r as Map<String, dynamic>;
  }

  Future<void> setAiSubscriptionStatus({
    required String fromAddress,
    required String symbol,
    required String status, // active | paused | canceled
  }) async {
    final allowed = {'active', 'paused', 'canceled'};
    if (!allowed.contains(status)) {
      throw ArgumentError('status must be one of $allowed');
    }
    await _authedPatch('/ai/subscriptions/${symbol.toUpperCase()}', {
      'fromAddress': fromAddress,
      'status': status,
    });
  }



  // -------------------------------- Referrals ---------------------------------
  Future<Map<String, dynamic>> getReferralSummary() async {
    final r = await _authedGet('/referrals/me');
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> createReferralCode({required String code}) async {
    final r = await _authedPost('/referrals/code', {'code': code});
    return Map<String, dynamic>.from(r as Map);
  }
  // Lists your direct referees
// lib/services/api/wallet_api.dart

// Add or fix this method
  Future<List<Map<String, dynamic>>> listReferrals({int limit = 200}) async {
    final r = await _authedGet('/referrals/list?limit=$limit');
    return (r as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }


  Future<List<Map<String, dynamic>>> listReferralCommissions() async {
    final r = await _authedGet('/referrals/commissions');
    return (r as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }


}
