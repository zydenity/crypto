import 'dart:async';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../../services/api/wallet_api.dart';
import '../../core/app_colors.dart';

class AiTradeScreen extends StatefulWidget {
  const AiTradeScreen({super.key});
  @override
  State<AiTradeScreen> createState() => _AiTradeScreenState();
}

class _AiTradeScreenState extends State<AiTradeScreen> {
  // Shared term to use across the UI for this action.
  // Use this same string anywhere you want the "transfer back to balance" wording.
  static const String kTermTransferToBalance = 'Return to Balance';

  bool _loading = true;
  List<_Coin> _all = [];
  String _filterTab = 'All';
  String _query = '';
  Timer? _poller;

  // funds & subs
  String _address = '';
  double _available = 0.0; // spendable USDT from /balance
  final Map<String, double> _amounts = {}; // symbol -> USDT allocation
  final Map<String, double> _rates = {};   // symbol -> daily rate (0.02 / 0.03 / 0.05)
  final Map<String, String> _starts = {};  // symbol -> start date (YYYY-MM-DD)
  final Map<String, String> _ends = {};    // symbol -> end date   (YYYY-MM-DD)

  // Server-driven profit summary (overall + today)
  double _overallBase = 0.0;   // lifetime credited up to start-of-today
  double _todayCredited = 0.0; // credited so far today (server)
  double _todayExpected = 0.0; // full-day target (server)
  DateTime? _profitFetchAt;    // local time when we fetched
  double _perSec = 0.0;        // expected / 86400

  // UI running tick
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    await _load();                   // market
    await _refreshFinances();        // sets address, amounts, rates
    await _refreshOverallProfit();   // needs _address
    _startPoller();
    _startTicker();
  }

  @override
  void dispose() {
    _poller?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _startPoller() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(seconds: 15), (_) async {
      await _load();
      await _refreshFinances();
      await _refreshOverallProfit();
    });
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {}); // drives smooth number
    });
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final rows = await WalletApi.instance.listMarketCoins();
      if (!mounted) return;
      setState(() {
        _all = rows
            .map((m) => _Coin.fromJson(m))
        // ⬇️ Exclude USDT from the market list
            .where((c) => c.symbol.toUpperCase() != 'USDT')
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load market: $e')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------- helpers ----------
  double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  String _dateOnly(String? s) {
    if (s == null) return '';
    final str = s.trim();
    if (str.isEmpty) return '';
    final m = RegExp(r'^\d{4}-\d{2}-\d{2}').firstMatch(str);
    // works for "2025-10-03T00:00:00Z" or "2025-10-03 00:00:00"
    return m?.group(0) ?? str.split('T').first.split(' ').first;
  }

  Widget _usdtBadge(Color c) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      color: c.withOpacity(.10),
      shape: BoxShape.circle,
      border: Border.all(color: c.withOpacity(.45)),
    ),
    alignment: Alignment.center,
    child: Text('₮', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: c)),
  );

  // USDT icon + amount
  Widget _usdtAmount(num amount, {TextStyle? style, bool showTicker = false}) {
    final s = amount.toStringAsFixed(2);
    final c = style?.color ?? Colors.white;
    return RichText(
      text: TextSpan(
        style: style ?? const TextStyle(color: Colors.white),
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _usdtBadge(c),
            ),
          ),
          TextSpan(text: s),
          if (showTicker) TextSpan(text: ' USDT', style: TextStyle(color: c.withOpacity(.9))),
        ],
      ),
    );
  }

  // Always green for "profit" badges
  Color _chipBgGain() => Colors.greenAccent.withOpacity(.16);
  Color _chipFgGain() => Colors.greenAccent;

  String _pairLabel(_Coin c) => c.symbol.toUpperCase() == 'USDT' ? 'USDT' : '${c.symbol.toUpperCase()}/USDT';

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.primary.withOpacity(.35), width: 1),
      ),
      child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }

  Widget _pillW(Widget child) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withOpacity(.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.primary.withOpacity(.35), width: 1),
      ),
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
        child: Row(mainAxisSize: MainAxisSize.min, children: [child]),
      ),
    );
  }

  // contract rates (for Set Amount sheet)
  double _rateForDays(int d) {
    if (d <= 7) return 0.02;
    if (d <= 15) return 0.03;
    if (d <= 30) return 0.05;
    if (d <= 60) return 0.05;
    return 0.03;
  }

  String _ratePctText(double r) => '${(r * 100).toStringAsFixed(0)}%';

  Future<void> _refreshFinances() async {
    try {
      final addr = await WalletApi.instance.getDefaultAddress();
      if (addr == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No default wallet found')));
        return;
      }
      final bal = await WalletApi.instance.getBalance(address: addr, tokenSymbol: 'USDT');
      final subs = await WalletApi.instance.listAiSubscriptions(address: addr);

      if (!mounted) return;
      setState(() {
        _address = addr;
        _available = _asDouble(bal['verified']);
        _amounts.clear();
        _rates.clear();
        _starts.clear();
        _ends.clear();
        for (final s in subs) {
          final sym = (s['symbol'] as String).toUpperCase();
          final amt = _asDouble(s['amountUsdt']);
          final status = (s['status'] as String).toLowerCase();
          final rate = _asDouble(s['rateDaily']);
          final start = (s['startDate'] ?? '').toString();
          final end = (s['endDate'] ?? '').toString();
          if (status == 'active') {
            _amounts[sym] = amt;
            if (rate > 0) _rates[sym] = rate;
            if (start.isNotEmpty) _starts[sym] = _dateOnly(start);
            if (end.isNotEmpty)   _ends[sym]   = _dateOnly(end);
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Balance/subscriptions failed: $e')));
    }
  }

  // ------- server-driven overall profit summary -------
  Future<void> _refreshOverallProfit() async {
    if (_address.isEmpty) return;
    try {
      // expects: { totalCredited, todayCredited, todayExpected }
      final m = await WalletApi.instance.getAiProfitOverall(address: _address);
      final totalCredited = (m['totalCredited'] ?? 0).toDouble();
      final todayCredited = (m['todayCredited'] ?? 0).toDouble();
      final todayExpected = (m['todayExpected'] ?? 0).toDouble();
      if (!mounted) return;
      setState(() {
        _overallBase   = totalCredited - todayCredited; // lifetime up to 00:00
        _todayCredited = todayCredited;
        _todayExpected = todayExpected;
        _perSec        = _todayExpected > 0 ? (_todayExpected / 86400.0) : 0.0;
        _profitFetchAt = DateTime.now();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Overall profit fetch failed: $e")),
      );
    }
  }

  // Smooth increment between polls, returns OVERALL amount
  double _smoothOverallAccrued() {
    if (_profitFetchAt == null) return _overallBase + _todayCredited;
    final secs = DateTime.now().difference(_profitFetchAt!).inSeconds;
    var todaySmooth = _todayCredited + (_perSec * secs);
    if (_todayExpected > 0 && todaySmooth > _todayExpected) {
      todaySmooth = _todayExpected;
    }
    return _overallBase + todaySmooth;
  }

  List<_Coin> get _visible {
    // ⬇️ Ensure USDT never appears in the UI list
    var list = _all.where((c) => c.symbol.toUpperCase() != 'USDT').toList();

    if (_filterTab == 'Gainers') list = list.where((c) => c.change24h > 0).toList();
    else if (_filterTab == 'Losers') list = list.where((c) => c.change24h < 0).toList();

    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      list = list.where((c) => c.name.toLowerCase().contains(q) || c.symbol.toLowerCase().contains(q)).toList();
    }
    return list;
  }

  double _getAmount(_Coin c) => _amounts[c.symbol.toUpperCase()] ?? 0.0;
  double _getRate(_Coin c) => _rates[c.symbol.toUpperCase()] ?? 0.0;
  String? _getStart(_Coin c) => _starts[c.symbol.toUpperCase()];
  String? _getEnd(_Coin c) => _ends[c.symbol.toUpperCase()];

  bool _isLocked(_Coin c) {
    final endStr = _getEnd(c);
    if (endStr == null || endStr.isEmpty) return false;
    DateTime? end;
    try { end = DateTime.parse(endStr); } catch (_) { return false; }
    // lock lasts until end-of-day (23:59:59) of end date
    final endOfDay = DateTime(end.year, end.month, end.day, 23, 59, 59);
    return DateTime.now().isBefore(endOfDay);
  }

  Duration? _timeUntilUnlock(_Coin c) {
    final endStr = _getEnd(c);
    if (endStr == null || endStr.isEmpty) return null;
    DateTime? end;
    try { end = DateTime.parse(endStr); } catch (_) { return null; }
    final endOfDay = DateTime(end.year, end.month, end.day, 23, 59, 59);
    final now = DateTime.now();
    if (!now.isBefore(endOfDay)) return Duration.zero;
    return endOfDay.difference(now);
  }

  String _fmtEta(Duration d) {
    final dys = d.inDays;
    final hrs = d.inHours % 24;
    final mins = d.inMinutes % 60;
    if (dys > 0) return '${dys}d ${hrs}h';
    if (hrs > 0) return '${hrs}h ${mins}m';
    return '${mins}m';
  }

  // per-coin visual (profit for *today*, smooth)
  double _runningProfitToday(_Coin c) {
    final amount = _getAmount(c);
    final rate = _getRate(c);
    if (amount <= 0 || rate <= 0) return 0.0;
    final now = DateTime.now();
    final secs = now.difference(DateTime(now.year, now.month, now.day)).inSeconds;
    return amount * rate * (secs / 86400.0);
  }

  // ===== Real-time Total % (accumulated so far) =====
  double _elapsedDaysFraction(_Coin c) {
    final sStr = _getStart(c);
    final eStr = _getEnd(c);
    if (sStr == null || sStr.isEmpty || eStr == null || eStr.isEmpty) return 0.0;

    DateTime s, e;
    try {
      s = DateTime.parse(sStr);
      e = DateTime.parse(eStr);
    } catch (_) {
      return 0.0;
    }

    final start = DateTime(s.year, s.month, s.day); // 00:00 local
    final end   = DateTime(e.year, e.month, e.day); // end day inclusive
    final totalDays = end.difference(start).inDays + 1;
    if (totalDays <= 0) return 0.0;

    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);

    if (todayStart.isBefore(start)) return 0.0;
    if (todayStart.isAfter(end)) return totalDays.toDouble();

    final fullDays = todayStart.difference(start).inDays; // 0..totalDays-1
    final secsToday = now.difference(todayStart).inSeconds;
    final fracToday = (secsToday / 86400.0).clamp(0.0, 1.0);

    final elapsed = fullDays + fracToday;
    return elapsed.clamp(0.0, totalDays.toDouble());
  }

  double _totalPctRealtime(_Coin c) {
    final r = _getRate(c);
    if (r <= 0) return 0.0;
    final elapsedDays = _elapsedDaysFraction(c);
    // non-compounding: total% = daily_rate × elapsed_days × 100
    return r * elapsedDays * 100.0;
  }

  Future<void> _setAmountAndSubscribe(_Coin c) async {
    if (_address.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No default wallet address.')));
      return;
    }
    final sym = c.symbol.toUpperCase();
    final oldAmt = _getAmount(c);
    final controller = TextEditingController(text: oldAmt > 0 ? oldAmt.toStringAsFixed(2) : '');
    final maxAllowed = _getAmount(c) + _available;

    // contract picker state
    final contractOptions = const [7, 15, 30, 60];
    int selectedDays = 15;

    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: AppColors.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setBS) {
          final rate = _rateForDays(selectedDays);
          return Padding(
            padding: EdgeInsets.only(
              left: 16, right: 16, top: 16,
              bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 12),
                Text('Set Amount for ${_pairLabel(c)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),

                // Contract selector
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Contract', style: TextStyle(color: Colors.white.withOpacity(.9), fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: contractOptions.map((d) {
                    final label = d == 7 ? '1 week' : '$d days';
                    return ChoiceChip(
                      label: Text(label),
                      selected: selectedDays == d,
                      onSelected: (_) => setBS(() => selectedDays = d),
                      selectedColor: AppColors.primary.withOpacity(.25),
                      backgroundColor: Colors.white12,
                      labelStyle: const TextStyle(fontWeight: FontWeight.w700),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _pill('Daily rate: ${_ratePctText(rate)}'),
                ),

                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(children: [
                      const Text('Available: ', style: TextStyle(color: Colors.white70)),
                      _usdtAmount(_available, style: const TextStyle(color: Colors.white70)),
                    ]),
                    Row(children: [
                      const Text('Max: ', style: TextStyle(color: Colors.white70)),
                      _usdtAmount(maxAllowed, style: const TextStyle(color: Colors.white70)),
                    ]),
                  ],
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Amount (USDT)',
                    hintText: 'e.g. 50',
                    filled: true,
                    fillColor: Colors.black12,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel'))),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () async {
                          final raw = controller.text.replaceAll(',', '').trim();
                          final v = double.tryParse(raw);
                          if (v == null || v <= 0) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid amount > 0')));
                            return;
                          }
                          if (v > maxAllowed) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Insufficient balance. You can allocate up to ${maxAllowed.toStringAsFixed(2)} USDT')),
                            );
                            return;
                          }
                          try {
                            await WalletApi.instance.upsertAiSubscription(
                              fromAddress: _address,
                              symbol: sym,
                              amountUsdt: v,
                              contractDays: selectedDays, // send contract
                            );
                            await _refreshFinances();       // principal lock affects available
                            await _refreshOverallProfit();  // summary may change
                            if (!mounted) return;
                            Navigator.pop(ctx, true);
                          } catch (e) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Subscription failed: $e')));
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: const Text('Save & Subscribe'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
            ),
          );
        });
      },
    );

    if (ok == true && mounted) {
      final a = _amounts[sym] ?? 0;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('Subscribed ${_pairLabel(c)} with '),
            const SizedBox(width: 4),
            _usdtAmount(a),
          ]),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _onSubscribe(_Coin c) => _setAmountAndSubscribe(c);

  // ===== NEW: Return allocation back to spendable balance =====
  Future<void> _returnToBalance(_Coin c) async {
    if (_address.isEmpty) return;
    final sym = c.symbol.toUpperCase();
    final amt = _getAmount(c);
    if (amt <= 0) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.card,
        title: Text(kTermTransferToBalance),
        content: Text(
          'This will cancel your ${_pairLabel(c)} allocation and return ${amt.toStringAsFixed(2)} USDT to your wallet balance. '
              'You will stop earning from this allocation.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep Earning')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
            child: Text(kTermTransferToBalance),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      // Requires WalletApi to implement PATCH /ai/subscriptions/:symbol with {fromAddress, status:'canceled'}
      await WalletApi.instance.setAiSubscriptionStatus(
        symbol: sym,
        fromAddress: _address,
        status: 'canceled',
      );
      await _refreshFinances();
      await _refreshOverallProfit();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$kTermTransferToBalance successful • '),
            const SizedBox(width: 4),
            _usdtAmount(amt, style: const TextStyle(color: Colors.white)),
          ]),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to $kTermTransferToBalance: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final smoothOverall = _smoothOverallAccrued();

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)),
        title: const Text('AI Trade', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () async => await Future.wait([_load(), _refreshFinances(), _refreshOverallProfit()]),
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => await Future.wait([_load(), _refreshFinances(), _refreshOverallProfit()]),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            // segmented
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(color: AppColors.card, borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Expanded(
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(color: AppColors.primary.withOpacity(.2), borderRadius: BorderRadius.circular(10)),
                    alignment: Alignment.center,
                    child: const Text('Amount', style: TextStyle(fontWeight: FontWeight.w700)),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Container(
                    height: 36,
                    decoration: BoxDecoration(color: Colors.transparent, borderRadius: BorderRadius.circular(10)),
                    alignment: Alignment.center,
                    child: const Text('Market', style: TextStyle(color: Colors.white70)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),

            if (_address.isNotEmpty) ...[
              // Available
              Row(
                children: [
                  const Icon(Icons.account_balance_wallet, size: 16, color: Colors.white70),
                  const SizedBox(width: 6),
                  const Text('Available: ', style: TextStyle(color: Colors.white70)),
                  _usdtAmount(_available, style: const TextStyle(color: Colors.white70)),
                ],
              ),
              const SizedBox(height: 6),
              // Overall AI profit — SERVER-DRIVEN (smooth ticking)
              Row(
                children: [
                  const Icon(Icons.trending_up, size: 16, color: Colors.white70),
                  const SizedBox(width: 6),
                  const Text('Overall AI profit: ', style: TextStyle(color: Colors.white70)),
                  _usdtAmount(smoothOverall, style: const TextStyle(color: Colors.greenAccent)),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // search + tabs
            TextField(
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                hintText: 'Search coin (e.g. BTC, Ether…)',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: AppColors.card,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                for (final t in const ['Favorite','All','Gainers','Losers'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: ChoiceChip(
                      label: Text(t),
                      selected: _filterTab == t,
                      onSelected: t == 'Favorite' ? null : (s) { if (s) setState(() => _filterTab = t); },
                      selectedColor: AppColors.primary.withOpacity(.22),
                      backgroundColor: AppColors.card,
                      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),

            // header (static)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: const [
                Expanded(flex: 5, child: Text('Pair / Name', style: TextStyle(color: Colors.white70))),
                Expanded(flex: 4, child: Text('Amount', style: TextStyle(color: Colors.white70))),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text('Daily / Total %', style: TextStyle(color: Colors.white70)),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1, color: Colors.white12),

            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('No results', style: TextStyle(color: Colors.white70))),
              )
            else
              ..._visible.map((c) {
                final title = _pairLabel(c);
                final amount = _getAmount(c);
                final dailyRate = _getRate(c);
                final profitToday = _runningProfitToday(c);
                final start = _getStart(c);
                final end = _getEnd(c);

                final hasSub = amount > 0 && dailyRate > 0;
                final ratePctText = hasSub ? '${(dailyRate * 100).toStringAsFixed(0)}%' : '—';
                final totalPctRt   = hasSub ? _totalPctRealtime(c) : 0.0;
                final totalPctText = hasSub ? '${totalPctRt.toStringAsFixed(0)}%' : '—';

                final locked = hasSub && _isLocked(c);
                final eta = locked ? _timeUntilUnlock(c) : null;

                final Widget amountCell = hasSub
                    ? _usdtAmount(
                  amount,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
                )
                    : InkWell(
                  onTap: () => _setAmountAndSubscribe(c),
                  child: Text(
                    '0',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.white70,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                );

                return Column(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      children: [
                        // top row
                        Row(children: [
                          Expanded(
                            flex: 5,
                            child: Row(children: [
                              CircleAvatar(
                                radius: 18,
                                backgroundColor: Colors.white12,
                                backgroundImage: c.image.isNotEmpty ? NetworkImage(c.image) : null,
                                onBackgroundImageError: (_, __) {},
                                child: c.image.isEmpty ? const Icon(FontAwesomeIcons.coins, size: 14) : null,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                                    Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withOpacity(.7))),
                                  ],
                                ),
                              ),
                            ]),
                          ),
                          // amount cell
                          Expanded(flex: 4, child: amountCell),
                          // daily + total % (right aligned)
                          Expanded(
                            flex: 3,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(color: _chipBgGain(), borderRadius: BorderRadius.circular(8)),
                                    child: Text(
                                      ratePctText, // Daily %
                                      style: TextStyle(color: _chipFgGain(), fontWeight: FontWeight.w700, fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Total: $totalPctText', // Real-time total %
                                    style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ]),
                        const SizedBox(height: 8),

                        // bottom row
                        Row(
                          children: [
                            Expanded(
                              flex: 7,
                              child: Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  _pill('AI Trading'),
                                  _pill('Daily: ${_ratePctText(dailyRate)}'),
                                  if (start != null && start.isNotEmpty && end != null && end.isNotEmpty)
                                    _pill('Contract: ${_dateOnly(start)} → ${_dateOnly(end)}')
                                  else if (end != null && end.isNotEmpty)
                                    _pill('Ends: ${_dateOnly(end)}'),
                                  if (locked && eta != null) _pill('Unlocks in: ${_fmtEta(eta)}'),
                                  if (amount > 0)
                                    _pillW(Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text('Profit today: '),
                                        _usdtAmount(
                                          profitToday,
                                          style: const TextStyle(color: Colors.greenAccent),
                                        ),
                                      ],
                                    )),
                                  if (hasSub)
                                    _pill('Total: $totalPctText'),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 5,
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  if (!hasSub) ...[
                                    // No active lock-in: user can configure + subscribe

                                    const SizedBox(width: 8),
                                    ElevatedButton(
                                      onPressed: () => _onSubscribe(c),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primary,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      child: const Text('Su5bscribe'),
                                    ),
                                  ] else ...[
                                    // NEW: Return to Balance (disabled while locked)
                                    OutlinedButton(
                                      onPressed: _isLocked(c) ? null : () => _returnToBalance(c),
                                      style: OutlinedButton.styleFrom(
                                        side: BorderSide(color: AppColors.primary.withOpacity(.6)),
                                        foregroundColor: Colors.white,
                                      ),
                                      child: Text(kTermTransferToBalance),
                                    ),
                                    const SizedBox(width: 8),
                                    // Active (or ended) sub: show Renew. Disabled while still locked.
                                    ElevatedButton(
                                      onPressed: _isLocked(c) ? null : () => _onSubscribe(c), // reuse same flow
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primary,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      ),
                                      child: const Text('Renew'),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                ]);
              }).toList(),
          ],
        ),
      ),
    );
  }
}

class _Coin {
  final String id, symbol, name, image;
  final double price, change24h;
  final int? rank;
  _Coin({
    required this.id,
    required this.symbol,
    required this.name,
    required this.image,
    required this.price,
    required this.change24h,
    this.rank,
  });

  static double _d(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  factory _Coin.fromJson(Map<String, dynamic> m) => _Coin(
    id: (m['id'] ?? '').toString(),
    symbol: (m['symbol'] ?? '').toString(),
    name: (m['name'] ?? '').toString(),
    image: (m['logo'] ?? m['image'] ?? '').toString(),
    price: _d(m['price'] ?? m['pricePhp'] ?? m['current_price']),
    change24h: _d(m['change24h'] ?? m['price_change_percentage_24h_in_currency']),
    rank: (m['rank'] is int) ? m['rank'] as int : int.tryParse('${m['rank'] ?? ''}'),
  );
}
