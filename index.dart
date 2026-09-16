// NexusGGR / FiversCan API — Dart 3 integration sample (dart:io + dart:convert, no packages)
// ==========================================================================================
// Endpoint  : POST https://{API_SERVER}          (JSON in, JSON out)
// Auth      : every request body carries agent_code + agent_token
// Response  : {"status": 1, "msg": "SUCCESS", ...}   on success
//             {"status": 0, "msg": "<ERROR>"}        on failure
// Methods   : provider_list, game_list, user_create, user_deposit,
//             game_launch, money_info, user_withdraw
// API access: https://t.me/casino_api777  ·  https://nexusggr.games
//
// Run:
//   FVS_API_URL=https://api.example.com FVS_AGENT_CODE=... FVS_AGENT_TOKEN=... dart run index.dart
// (in Flutter, swap HttpClient for package:http — the request/response shapes are identical)

import 'dart:convert';
import 'dart:io';

String env(String name, String fallback) {
  final value = Platform.environment[name];
  return (value == null || value.isEmpty) ? fallback : value;
}

/// Thrown when the API answers status != 1; [msg] is the API error code.
class FiversCanException implements Exception {
  final String method;
  final String msg;
  final String? detail;

  FiversCanException(this.method, this.msg, [this.detail]);

  @override
  String toString() => '$method failed: $msg${detail != null ? ' ($detail)' : ''}';
}

class FiversCanClient {
  final Uri apiUrl;
  final String agentCode;
  final String agentToken;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);

  FiversCanClient(String apiUrl, this.agentCode, this.agentToken) : apiUrl = Uri.parse(apiUrl);

  /// Low-level call: POST {method, agent_code, agent_token, ...params} and unwrap status.
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final body = {'method': method, 'agent_code': agentCode, 'agent_token': agentToken, ...params};

    final request = await _http.postUrl(apiUrl);
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw HttpException('$method: HTTP ${response.statusCode}', uri: apiUrl);
    }

    final data = jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;
    if (data['status'] != 1) {
      throw FiversCanException(method, (data['msg'] ?? 'unknown').toString(), data['detail']?.toString());
    }
    return data;
  }

  Future<Map<String, dynamic>> providerList() => call('provider_list');

  Future<Map<String, dynamic>> gameList(String providerCode) => call('game_list', {'provider_code': providerCode});

  Future<Map<String, dynamic>> userCreate(String userCode) => call('user_create', {'user_code': userCode});

  // amount is sent as a JSON number (num, not String); agentSign is an optional unique id ([A-Za-z0-9_])
  // that prevents double-charging when a request is retried
  Future<Map<String, dynamic>> userDeposit(String userCode, num amount, [String? agentSign]) =>
      call('user_deposit', _transferParams(userCode, amount, agentSign));

  Future<Map<String, dynamic>> userWithdraw(String userCode, num amount, [String? agentSign]) =>
      call('user_withdraw', _transferParams(userCode, amount, agentSign));

  Map<String, dynamic> _transferParams(String userCode, num amount, String? agentSign) => {
        'user_code': userCode,
        'amount': amount,
        if (agentSign != null) 'agent_sign': agentSign,
      };

  // Without userCode returns the agent balance only; send 'all_users': true to list every user
  Future<Map<String, dynamic>> moneyInfo([String? userCode]) =>
      call('money_info', {if (userCode != null) 'user_code': userCode});

  // gameCode may be empty for live-casino providers to open the lobby; rtp is optional
  Future<Map<String, dynamic>> gameLaunch({
    required String userCode,
    required String providerCode,
    String gameCode = '',
    String lang = 'en',
    String lobbyUrl = '',
    num? rtp,
  }) =>
      call('game_launch', {
        'user_code': userCode,
        'provider_code': providerCode,
        'game_code': gameCode,
        'lang': lang,
        'lobby_url': lobbyUrl,
        if (rtp != null) 'rtp': rtp,
      });

  void close() => _http.close();
}

Future<void> main() async {
  final fvs = FiversCanClient(
    env('FVS_API_URL', 'https://api.example.com'), // API server you received from NexusGGR
    env('FVS_AGENT_CODE', 'your_agent_code'),
    env('FVS_AGENT_TOKEN', 'your_agent_token'),
  );
  const userCode = 'demo_user';

  try {
    // 1. Providers available to this agent (status 1 = open, 0 = maintenance)
    final providers = ((await fvs.providerList())['providers'] as List).cast<Map<String, dynamic>>();
    final provider = providers.firstWhere((p) => p['status'] == 1, orElse: () => providers.first);
    final providerCode = provider['code'] as String;
    print('providers: ${providers.length}, using $providerCode');

    // 2. Games of that provider
    final games = ((await fvs.gameList(providerCode))['games'] as List).cast<Map<String, dynamic>>();
    final game = games.first;
    final gameCode = game['game_code'] as String;
    print('games: ${games.length}, first: $gameCode (${game['game_name']})');

    // 3. Create the player (idempotent: an existing user is fine)
    try {
      final created = await fvs.userCreate(userCode);
      print('user created: ${created['user_code']} (${created['fc_code']})');
    } on FiversCanException catch (e) {
      if (!e.msg.toLowerCase().contains('duplicated')) rethrow;
      print('user exists: $userCode');
    }

    // 4. Move funds agent -> player
    final dep = await fvs.userDeposit(userCode, 100, 'dep_${DateTime.now().millisecondsSinceEpoch}');
    print('deposit ok: agent=${dep['agent_balance']} user=${dep['user_balance']}');

    // 5. Get the game URL to open in the player's browser / iframe
    final launch = await fvs.gameLaunch(userCode: userCode, providerCode: providerCode, gameCode: gameCode, lang: 'en', lobbyUrl: 'https://your-site.com/lobby');
    print('launch_url: ${launch['launch_url']}');

    // 6. Balances
    final info = await fvs.moneyInfo(userCode);
    print('balance: agent=${info['agent']['balance']} user=${info['user']['balance']}');

    // 7. Move funds player -> agent
    final wd = await fvs.userWithdraw(userCode, 50, 'wd_${DateTime.now().millisecondsSinceEpoch}');
    print('withdraw ok: agent=${wd['agent_balance']} user=${wd['user_balance']}');
  } catch (e) {
    stderr.writeln(e);
    exitCode = 1;
  } finally {
    fvs.close();
  }
}
