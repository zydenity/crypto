import 'dart:async';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<void> init({String? seedDefaultAddress}) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'crypto_wallet.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE wallet_addresses (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            label TEXT,
            address TEXT NOT NULL UNIQUE,
            network TEXT DEFAULT 'ethereum',
            token_symbol TEXT DEFAULT 'USDT',
            is_default INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
    );

    // seed default address if table empty
    final count = Sqflite.firstIntValue(
      await _db!.rawQuery('SELECT COUNT(*) FROM wallet_addresses'),
    )!;
    if (count == 0 && seedDefaultAddress != null) {
      await upsertDefaultAddress(
        address: seedDefaultAddress,
        label: 'My Wallet',
        network: 'ethereum',
        tokenSymbol: 'USDT',
      );
    }
  }

  Future<void> upsertDefaultAddress({
    required String address,
    String label = 'My Wallet',
    String network = 'ethereum',
    String tokenSymbol = 'USDT',
  }) async {
    final db = _db!;
    await db.transaction((txn) async {
      await txn.update('wallet_addresses', {'is_default': 0});
      // insert or ignore then update
      await txn.insert(
        'wallet_addresses',
        {
          'label': label,
          'address': address,
          'network': network,
          'token_symbol': tokenSymbol,
          'is_default': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });
  }

  Future<String?> getDefaultAddress() async {
    final db = _db!;
    final rows = await db.query(
      'wallet_addresses',
      where: 'is_default = 1',
      limit: 1,
    );
    if (rows.isNotEmpty) return rows.first['address'] as String;
    // fallback to first row if no default set
    final any = await db.query('wallet_addresses', limit: 1);
    return any.isEmpty ? null : any.first['address'] as String;
  }

  Future<List<Map<String, Object?>>> getAllAddresses() async {
    return _db!.query('wallet_addresses', orderBy: 'is_default DESC, id DESC');
  }
}
