import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

late final http.Client _httpClient;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemProxyConfig.load();
  _httpClient = _createHttpClient();
  runApp(const WeightTrackerApp());
}

class AppConfig {
  static const clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const clientSecret = String.fromEnvironment('GOOGLE_CLIENT_SECRET');
  static const httpProxy = String.fromEnvironment('HTTP_PROXY');
  static const httpsProxy = String.fromEnvironment('HTTPS_PROXY');
  static const noProxy = String.fromEnvironment('NO_PROXY');
}

class SystemProxyConfig {
  static const _channel = MethodChannel('weight_tracker/proxy');

  static String? httpProxy;
  static String? httpsProxy;
  static String? noProxy;

  static Future<void> load() async {
    if (kIsWeb || !Platform.isMacOS) {
      return;
    }

    try {
      final data = await _channel.invokeMapMethod<String, dynamic>(
        'getSystemProxy',
      );
      if (data == null) {
        return;
      }

      final httpEnabled = data['httpEnabled'] == true;
      final httpHost = data['httpHost'] as String?;
      final httpPort = data['httpPort'] as int?;
      if (httpEnabled && httpHost != null && httpHost.isNotEmpty && httpPort != null) {
        httpProxy = 'http://$httpHost:$httpPort';
      }

      final httpsEnabled = data['httpsEnabled'] == true;
      final httpsHost = data['httpsHost'] as String?;
      final httpsPort = data['httpsPort'] as int?;
      if (httpsEnabled &&
          httpsHost != null &&
          httpsHost.isNotEmpty &&
          httpsPort != null) {
        httpsProxy = 'http://$httpsHost:$httpsPort';
      }

      final exceptions =
          (data['exceptions'] as List<dynamic>? ?? <dynamic>[])
              .whereType<String>()
              .where((e) => e.trim().isNotEmpty)
              .toSet();
      exceptions.add('localhost');
      exceptions.add('127.0.0.1');
      noProxy = exceptions.join(',');
    } catch (_) {
      // Ignore and continue without system proxy.
    }
  }
}

String? _pickProxyValue(List<String?> values) {
  for (final value in values) {
    if (value != null && value.trim().isNotEmpty) {
      return value;
    }
  }
  return null;
}

http.Client _createHttpClient() {
  if (kIsWeb) {
    return http.Client();
  }

  final environment = Map<String, String>.from(Platform.environment);
  final effectiveHttpProxy = _pickProxyValue(<String?>[
    AppConfig.httpProxy,
    environment['http_proxy'],
    environment['HTTP_PROXY'],
    SystemProxyConfig.httpProxy,
  ]);
  final effectiveHttpsProxy = _pickProxyValue(<String?>[
    AppConfig.httpsProxy,
    environment['https_proxy'],
    environment['HTTPS_PROXY'],
    SystemProxyConfig.httpsProxy,
  ]);
  final effectiveNoProxy = _pickProxyValue(<String?>[
    AppConfig.noProxy,
    environment['no_proxy'],
    environment['NO_PROXY'],
    SystemProxyConfig.noProxy,
  ]);

  if (effectiveHttpProxy != null) {
    environment['http_proxy'] = effectiveHttpProxy;
    environment['HTTP_PROXY'] = effectiveHttpProxy;
  }
  if (effectiveHttpsProxy != null) {
    environment['https_proxy'] = effectiveHttpsProxy;
    environment['HTTPS_PROXY'] = effectiveHttpsProxy;
  }
  if (effectiveNoProxy != null) {
    environment['no_proxy'] = effectiveNoProxy;
    environment['NO_PROXY'] = effectiveNoProxy;
  }

  final ioHttpClient = HttpClient();
  ioHttpClient.findProxy = (uri) {
    return HttpClient.findProxyFromEnvironment(uri, environment: environment);
  };
  return IOClient(ioHttpClient);
}

class WeightEntry {
  WeightEntry({required this.date, required this.weightKg});

  final DateTime date;
  final double weightKg;

  Map<String, dynamic> toJson() => {
    'date': date.toIso8601String(),
    'weightKg': weightKg,
  };

  factory WeightEntry.fromJson(Map<String, dynamic> json) {
    return WeightEntry(
      date: DateTime.parse(json['date'] as String),
      weightKg: (json['weightKg'] as num).toDouble(),
    );
  }
}

class AuthResult {
  AuthResult({
    required this.accessToken,
    this.refreshToken,
    this.expiresInSeconds,
  });

  final String accessToken;
  final String? refreshToken;
  final int? expiresInSeconds;
}

class AuthSession {
  AuthSession({
    required this.accessToken,
    required this.expiresAtEpochMs,
    this.refreshToken,
  });

  final String accessToken;
  final int expiresAtEpochMs;
  final String? refreshToken;

  bool get isExpired =>
      DateTime.now().millisecondsSinceEpoch >= expiresAtEpochMs - 60000;
}

class GoogleAuthService {
  static const _scope = 'https://www.googleapis.com/auth/drive.appdata';

  static final Uri _authUri = Uri.parse(
    'https://accounts.google.com/o/oauth2/v2/auth',
  );

  static final Uri _tokenUri = Uri.parse('https://oauth2.googleapis.com/token');

  String _randomUrlSafe(int byteCount) {
    final random = Random.secure();
    final values = List<int>.generate(byteCount, (_) => random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }

  Future<AuthResult> signInWithPkce({
    void Function(String authUrl)? onManualOpenRequired,
  }) async {
    if (kIsWeb) {
      throw Exception(
        'PKCE loopback flow in this app is not supported on web.',
      );
    }
    if (AppConfig.clientId.isEmpty) {
      throw Exception(
        'GOOGLE_CLIENT_ID missing. Use a Google OAuth client of type "Desktop app".',
      );
    }

    final verifier = _randomUrlSafe(64);
    final challenge = base64Url
        .encode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');
    final state = _randomUrlSafe(24);

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}/oauth2callback';

    final authUrl = _authUri.replace(
      queryParameters: {
        'client_id': AppConfig.clientId,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': _scope,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': 'offline',
        'prompt': 'consent',
      },
    );

    var launched = false;
    try {
      launched = await launchUrl(authUrl, mode: LaunchMode.externalApplication);
    } catch (_) {
      launched = false;
    }
    if (!launched) {
      onManualOpenRequired?.call(authUrl.toString());
    }

    try {
      final callbackPath = '/oauth2callback';
      final iterator = StreamIterator<HttpRequest>(server);
      final deadline = DateTime.now().add(const Duration(minutes: 5));

      String? code;
      while (true) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining.isNegative) {
          throw TimeoutException('OAuth callback timed out.');
        }

        final hasRequest = await iterator.moveNext().timeout(remaining);
        if (!hasRequest) {
          throw Exception(
            'Google sign-in failed: callback server closed unexpectedly.',
          );
        }

        final req = iterator.current;
        if (req.uri.path != callbackPath) {
          req.response
            ..statusCode = 404
            ..headers.contentType = ContentType.text
            ..write('Not found');
          await req.response.close();
          continue;
        }

        final returnedState = req.uri.queryParameters['state'];
        final error = req.uri.queryParameters['error'];
        code = req.uri.queryParameters['code'];

        final responseHtml = (error == null && code != null)
            ? '<html><body><h3>Sign-in complete</h3><p>You can close this window.</p></body></html>'
            : '<html><body><h3>Sign-in failed</h3><p>${error ?? 'Invalid response'}</p></body></html>';

        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write(responseHtml);
        await req.response.close();

        if (error != null) {
          throw Exception('Google sign-in failed: $error');
        }
        if (code == null || returnedState != state) {
          throw Exception(
            'Google sign-in failed: invalid authorization response.',
          );
        }
        break;
      }

      final tokenResponse = await _httpClient.post(
        _tokenUri,
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': AppConfig.clientId,
          if (AppConfig.clientSecret.isNotEmpty)
            'client_secret': AppConfig.clientSecret,
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': redirectUri,
          'code_verifier': verifier,
        },
      );

      final tokenData = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
      if (tokenResponse.statusCode != 200 ||
          tokenData['access_token'] == null) {
        throw Exception('Token exchange failed: ${tokenResponse.body}');
      }

      return AuthResult(
        accessToken: tokenData['access_token'] as String,
        refreshToken: tokenData['refresh_token'] as String?,
        expiresInSeconds: (tokenData['expires_in'] as num?)?.toInt(),
      );
    } on TimeoutException {
      throw Exception(
        'Google sign-in timed out waiting for local callback at $redirectUri. '
        'If you use a proxy, bypass proxy for localhost and 127.0.0.1.',
      );
    } finally {
      await server.close(force: true);
    }
  }

  Future<AuthResult> refreshAccessToken(String refreshToken) async {
    final tokenResponse = await _httpClient.post(
      _tokenUri,
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'client_id': AppConfig.clientId,
        if (AppConfig.clientSecret.isNotEmpty)
          'client_secret': AppConfig.clientSecret,
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
      },
    );

    final tokenData = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
    if (tokenResponse.statusCode != 200 || tokenData['access_token'] == null) {
      throw Exception('Token refresh failed: ${tokenResponse.body}');
    }

    return AuthResult(
      accessToken: tokenData['access_token'] as String,
      refreshToken: refreshToken,
      expiresInSeconds: (tokenData['expires_in'] as num?)?.toInt(),
    );
  }
}

class AndroidGoogleAuthService {
  static const _scope = 'https://www.googleapis.com/auth/drive.appdata';
  final GoogleSignIn _googleSignIn = GoogleSignIn(scopes: <String>[_scope]);

  Future<AuthResult> signIn() async {
    final account =
        await _googleSignIn.signInSilently() ?? await _googleSignIn.signIn();
    if (account == null) {
      throw Exception('Google sign-in was cancelled.');
    }
    final auth = await account.authentication;
    final token = auth.accessToken;
    if (token == null || token.isEmpty) {
      throw Exception('Could not obtain Google access token.');
    }
    return AuthResult(accessToken: token);
  }

  Future<String?> getAccessTokenSilently() async {
    final account = await _googleSignIn.signInSilently();
    if (account == null) {
      return null;
    }
    final auth = await account.authentication;
    return auth.accessToken;
  }

  Future<void> signOut() => _googleSignIn.signOut();
}

class SessionStore {
  static const _kAccessToken = 'google_access_token';
  static const _kRefreshToken = 'google_refresh_token';
  static const _kExpiresAt = 'google_expires_at';

  Future<AuthSession?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final accessToken = prefs.getString(_kAccessToken);
    final expiresAt = prefs.getInt(_kExpiresAt);
    if (accessToken == null || expiresAt == null) {
      return null;
    }
    return AuthSession(
      accessToken: accessToken,
      expiresAtEpochMs: expiresAt,
      refreshToken: prefs.getString(_kRefreshToken),
    );
  }

  Future<void> write(AuthSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAccessToken, session.accessToken);
    await prefs.setInt(_kExpiresAt, session.expiresAtEpochMs);
    if (session.refreshToken == null || session.refreshToken!.isEmpty) {
      await prefs.remove(_kRefreshToken);
    } else {
      await prefs.setString(_kRefreshToken, session.refreshToken!);
    }
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAccessToken);
    await prefs.remove(_kExpiresAt);
    await prefs.remove(_kRefreshToken);
  }
}

class GoogleDriveWeightRepository {
  static final Uri _findFileUri = Uri.parse(
    'https://www.googleapis.com/drive/v3/files'
    '?spaces=appDataFolder'
    '&fields=files(id,name)'
    '&q=name%3D%27weights.json%27%20and%20%27appDataFolder%27%20in%20parents%20and%20trashed%3Dfalse',
  );

  Future<String?> _getFileId(String accessToken) async {
    final response = await _httpClient.get(
      _findFileUri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) {
      throw Exception('Lookup failed: ${response.body}');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final files = (data['files'] as List<dynamic>? ?? <dynamic>[])
        .cast<Map<String, dynamic>>();
    if (files.isEmpty) {
      return null;
    }
    return files.first['id'] as String;
  }

  Future<List<WeightEntry>> loadEntries(String accessToken) async {
    final fileId = await _getFileId(accessToken);
    if (fileId == null) {
      return <WeightEntry>[];
    }

    final contentUri = Uri.parse(
      'https://www.googleapis.com/drive/v3/files/$fileId?alt=media',
    );
    final response = await _httpClient.get(
      contentUri,
      headers: {'Authorization': 'Bearer $accessToken'},
    );

    if (response.statusCode != 200) {
      throw Exception('Load failed: ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      return <WeightEntry>[];
    }

    return decoded
        .cast<Map<String, dynamic>>()
        .map(WeightEntry.fromJson)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> saveEntries(
    String accessToken,
    List<WeightEntry> entries,
  ) async {
    final fileId = await _getFileId(accessToken);
    final payload = jsonEncode(entries.map((e) => e.toJson()).toList());

    if (fileId == null) {
      final createUri = Uri.parse(
        'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart',
      );
      const boundary = 'boundary_weight_tracker_upload';
      final metadata = jsonEncode({
        'name': 'weights.json',
        'parents': ['appDataFolder'],
      });

      final body =
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$metadata\r\n'
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$payload\r\n'
          '--$boundary--';

      final response = await _httpClient.post(
        createUri,
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Content-Type': 'multipart/related; boundary=$boundary',
        },
        body: body,
      );

      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('Create failed: ${response.body}');
      }
      return;
    }

    final updateUri = Uri.parse(
      'https://www.googleapis.com/upload/drive/v3/files/$fileId?uploadType=media',
    );
    final response = await _httpClient.patch(
      updateUri,
      headers: {
        'Authorization': 'Bearer $accessToken',
        'Content-Type': 'application/json',
      },
      body: payload,
    );

    if (response.statusCode != 200) {
      throw Exception('Save failed: ${response.body}');
    }
  }
}

class WeightTrackerApp extends StatelessWidget {
  const WeightTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weight Tracker',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
      ),
      home: const WeightTrackerPage(),
    );
  }
}

class WeightTrackerPage extends StatefulWidget {
  const WeightTrackerPage({super.key});

  @override
  State<WeightTrackerPage> createState() => _WeightTrackerPageState();
}

class _WeightTrackerPageState extends State<WeightTrackerPage> {
  final _authService = GoogleAuthService();
  final _androidAuthService = AndroidGoogleAuthService();
  final _repo = GoogleDriveWeightRepository();
  final _sessionStore = SessionStore();
  final _weightController = TextEditingController();
  final _dateFormat = DateFormat('yyyy-MM-dd');

  String? _accessToken;
  String? _manualAuthUrl;
  List<WeightEntry> _entries = <WeightEntry>[];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreSession());
  }

  @override
  void dispose() {
    _weightController.dispose();
    super.dispose();
  }

  AuthSession _toSession(AuthResult auth, {String? fallbackRefreshToken}) {
    final expires = auth.expiresInSeconds ?? 3600;
    return AuthSession(
      accessToken: auth.accessToken,
      expiresAtEpochMs: DateTime.now()
          .add(Duration(seconds: expires))
          .millisecondsSinceEpoch,
      refreshToken: auth.refreshToken ?? fallbackRefreshToken,
    );
  }

  Future<void> _restoreSession() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final token = await _androidAuthService.getAccessTokenSilently();
        if (token != null && token.isNotEmpty) {
          _accessToken = token;
          await _reloadFromGoogleDrive();
        }
        return;
      }

      final existing = await _sessionStore.read();
      if (existing == null) {
        return;
      }

      AuthSession session = existing;
      if (session.isExpired && session.refreshToken != null) {
        final refreshed = await _authService.refreshAccessToken(
          session.refreshToken!,
        );
        session = _toSession(
          refreshed,
          fallbackRefreshToken: session.refreshToken,
        );
        await _sessionStore.write(session);
      }

      if (session.isExpired) {
        await _sessionStore.clear();
        return;
      }

      _accessToken = session.accessToken;
      await _reloadFromGoogleDrive();
    } catch (_) {
      await _sessionStore.clear();
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _startSignIn() async {
    setState(() {
      _loading = true;
      _error = null;
      _manualAuthUrl = null;
    });

    try {
      if (!kIsWeb && Platform.isAndroid) {
        final auth = await _androidAuthService.signIn();
        _accessToken = auth.accessToken;
      } else {
        final auth = await _authService.signInWithPkce(
          onManualOpenRequired: (url) {
            if (!mounted) {
              return;
            }
            setState(() {
              _manualAuthUrl = url;
            });
          },
        );
        final session = _toSession(auth);
        _accessToken = session.accessToken;
        await _sessionStore.write(session);
      }
      await _reloadFromGoogleDrive();
    } catch (e) {
      setState(() {
        _error = '$e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _reloadFromGoogleDrive() async {
    if (!kIsWeb && Platform.isAndroid) {
      final refreshed = await _androidAuthService.getAccessTokenSilently();
      if (refreshed != null && refreshed.isNotEmpty) {
        _accessToken = refreshed;
      }
    }

    if (_accessToken == null || _accessToken!.isEmpty) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final loaded = await _repo.loadEntries(_accessToken!);
      setState(() {
        _entries = loaded;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
      });
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _addEntry() async {
    final raw = _weightController.text.trim();
    final weight = double.tryParse(raw);
    if (weight == null || weight <= 0) {
      setState(() {
        _error = 'Enter a valid positive weight in kg.';
      });
      return;
    }
    if (!kIsWeb && Platform.isAndroid) {
      final refreshed = await _androidAuthService.getAccessTokenSilently();
      if (refreshed != null && refreshed.isNotEmpty) {
        _accessToken = refreshed;
      }
    }

    if (_accessToken == null || _accessToken!.isEmpty) {
      setState(() {
        _error = 'Sign in to Google Drive first.';
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = <WeightEntry>[
        WeightEntry(date: DateTime.now().toUtc(), weightKg: weight),
        ..._entries,
      ]..sort((a, b) => b.date.compareTo(a.date));
      await _repo.saveEntries(_accessToken!, next);
      _entries = next;
      _weightController.clear();
    } catch (e) {
      _error = '$e';
    } finally {
      setState(() {
        _loading = false;
      });
    }
  }

  Future<void> _signOut() async {
    if (!kIsWeb && Platform.isAndroid) {
      await _androidAuthService.signOut();
    } else {
      await _sessionStore.clear();
    }
    setState(() {
      _accessToken = null;
      _entries = <WeightEntry>[];
      _manualAuthUrl = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final signedIn = _accessToken != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Weight Tracker'),
        actions: [
          if (signedIn)
            IconButton(
              onPressed: _loading ? null : _signOut,
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
            ),
          IconButton(
            onPressed: signedIn && !_loading ? _reloadFromGoogleDrive : null,
            icon: const Icon(Icons.sync),
            tooltip: 'Sync from Google Drive',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!signedIn)
              FilledButton(
                onPressed: _loading ? null : _startSignIn,
                child: const Text('Sign in with Google'),
              ),
            if (_manualAuthUrl != null && !signedIn) ...[
              const SizedBox(height: 12),
              const Text(
                'Browser launch failed. Open this URL manually to continue sign-in:',
              ),
              const SizedBox(height: 8),
              SelectableText(_manualAuthUrl!),
            ],
            if (signedIn) ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _weightController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Weight (kg)',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _loading ? null : _addEntry,
                    child: const Text('Add'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _entries.isEmpty
                    ? const Center(child: Text('No entries yet.'))
                    : ListView.separated(
                        itemCount: _entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          final localDate = entry.date.toLocal();
                          return ListTile(
                            title: Text(
                              '${entry.weightKg.toStringAsFixed(1)} kg',
                            ),
                            subtitle: Text(_dateFormat.format(localDate)),
                          );
                        },
                      ),
              ),
            ],
            if (_loading) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
