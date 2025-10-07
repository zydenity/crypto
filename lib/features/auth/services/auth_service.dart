// lib/features/auth/services/auth_service.dart
import 'dart:convert';
import 'package:flutter/foundation.dart'; // kIsWeb, defaultTargetPlatform, TargetPlatform
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  static const _kTokenKey = 'auth_jwt';
  static const _kUserKey  = 'auth_user';

  String? _token;
  Map<String, dynamic>? _user;

  // ---------------------------------------------------------------------------
  // Config / getters
  // ---------------------------------------------------------------------------
  final _apiBaseFromEnv = String.fromEnvironment('API_BASE', defaultValue: '');

  String get baseUrl {
    // If provided at build time, always use it (prod/staging/web/mobile)
    if (_apiBaseFromEnv.isNotEmpty) return _apiBaseFromEnv;

    // Dev fallbacks:
    final isAndroidEmu = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    return isAndroidEmu ? 'http://10.0.2.2:3000' : 'http://localhost:3000';
  }

  String? get token => _token;
  Map<String, dynamic>? get user  => _user;
  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  Future<void> init() async {
    final sp = await SharedPreferences.getInstance();
    _token = sp.getString(_kTokenKey);
    final u = sp.getString(_kUserKey);
    _user = (u != null && u.isNotEmpty)
        ? (jsonDecode(u) as Map<String, dynamic>)
        : null;
  }

  Map<String, String> authHeaders() => {
    if (_token != null && _token!.isNotEmpty) 'Authorization': 'Bearer $_token',
    'Accept': 'application/json',
  };

  // ---------------------------------------------------------------------------
  // Auth flows
  // ---------------------------------------------------------------------------

  /// Registers a new user.
  /// Returns the assigned wallet address if the backend includes it; otherwise null.
  ///
  /// If the backend returns { token, user }, we save the session immediately.
  /// If it only returns { ok, userId }, we automatically call [login] so the
  /// app lands authenticated after sign-up.
  Future<String?> register({
    required String name,
    required String identifier,
    required String password,
    String? referralCode, // optional
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({
        'name': name,
        'identifier': identifier,
        'password': password,
        if (referralCode != null && referralCode.isNotEmpty) 'referralCode': referralCode,
      }),
    );

    if (resp.statusCode != 201 && resp.statusCode != 200) {
      throw Exception('Register failed: ${resp.statusCode} ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;

    final token = body['token'] as String?;
    final user  = body['user']  as Map<String, dynamic>?;

    if (token != null && user != null) {
      await _saveSession(token, user);
    } else {
      // Older shape: only { ok, userId } -> auto-login with same credentials.
      await login(identifier: identifier, password: password);
    }

    // Accept both shapes for the assigned address:
    // - { assignedAddress: "0x..." } (older)
    // - { wallet: { address: "0x..." } } (current)
    final assignedFromField  = body['assignedAddress'] as String?;
    final assignedFromWallet =
    (body['wallet'] is Map<String, dynamic>) ? (body['wallet']['address'] as String?) : null;

    return assignedFromField ?? assignedFromWallet;
  }

  /// Logs the user in and persists token + user.
  Future<bool> login({
    required String identifier,
    required String password,
  }) async {
    final resp = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: const {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      body: jsonEncode({'identifier': identifier, 'password': password}),
    );

    if (resp.statusCode != 200) {
      throw Exception('Login failed: ${resp.statusCode} ${resp.body}');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final token = body['token'] as String?;
    final user  = body['user']  as Map<String, dynamic>?;

    if (token == null || user == null) {
      throw Exception('Malformed login response');
    }

    await _saveSession(token, user);
    return true;
  }

  Future<void> logout() async {
    _token = null;
    _user  = null;
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kTokenKey);
    await sp.remove(_kUserKey);
  }

  // ---------------------------------------------------------------------------
  // Storage
  // ---------------------------------------------------------------------------
  Future<void> _saveSession(String token, Map<String, dynamic> user) async {
    _token = token;
    _user  = user;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kTokenKey, token);
    await sp.setString(_kUserKey, jsonEncode(user));
  }
}
