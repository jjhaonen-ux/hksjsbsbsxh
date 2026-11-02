import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'models/models.dart';
import 'screens/create_repo_screen.dart';
import 'screens/token_screen.dart';
import 'services/github_service.dart';
import 'services/token_store.dart';
import 'services/zip_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Folders left in the temp directory by a run that was killed mid-way.
  unawaited(ZipService.cleanupStale());
  runApp(const GitHubZipPusherApp());
}

class GitHubZipPusherApp extends StatelessWidget {
  const GitHubZipPusherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GitHub ZIP Pusher',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1F6FEB),
        brightness: Brightness.dark,
      ),
      home: const _Gate(),
    );
  }
}

/// Holds an authenticated session: the raw token plus the resolved user.
class Session {
  const Session({required this.token, required this.user});
  final String token;
  final GitHubUser user;
}

class _Gate extends StatefulWidget {
  const _Gate();

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  Session? _session;
  GitHubService? _service;
  bool _loading = true;

  /// Set when the saved token could not be checked because of the network or
  /// a GitHub outage. The token is kept: it may well still be valid.
  String? _restoreError;

  /// Why the token screen is shown (the saved token was rejected).
  String? _tokenNotice;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _service?.close();
    super.dispose();
  }

  /// Takes over [service], the one that already verified the token, so a
  /// login never leaves a second HTTP client behind. [warning] (for example
  /// "the token could not be saved") is shown once on the next screen.
  void _setSession(
    String token,
    GitHubUser user,
    GitHubService service, [
    String? warning,
  ]) {
    final previous = _service;
    setState(() {
      _session = Session(token: token, user: user);
      _service = service;
      _restoreError = null;
      _tokenNotice = null;
    });
    if (previous != null && !identical(previous, service)) previous.close();
    if (warning != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(warning), duration: const Duration(seconds: 8)),
      );
    }
  }

  void _signedOut() {
    final previous = _service;
    setState(() {
      _session = null;
      _service = null;
    });
    previous?.close();
  }

  /// "Retry" button: back to the spinner, then check the saved token again.
  Future<void> _retry() {
    setState(() {
      _loading = true;
      _restoreError = null;
    });
    return _restore();
  }

  Future<void> _restore() async {
    // Everything that can throw lives inside the try: an exception escaping
    // from here used to leave the spinner on screen forever.
    try {
      final token = await const TokenStore().read();
      if (token == null || token.isEmpty) return;
      final service = GitHubService(token: token);
      var handedOff = false;
      try {
        final user = await service.currentUser();
        if (!mounted) return;
        _setSession(token, user, service);
        handedOff = true;
      } on GitHubApiException catch (e) {
        if (e.statusCode == 401) {
          // GitHub itself says the token is bad (revoked, expired, deleted):
          // the only useful thing left is to ask for a new one.
          await _forgetToken();
          _tokenNotice = 'انتهت صلاحية التوكن المحفوظ أو أُلغي. '
              'أدخل توكنًا جديدًا للمتابعة.';
        } else {
          // No network, timeout, 5xx, rate limit…: this says nothing about
          // the token, so keep it and let the user retry.
          _restoreError = e.toString();
        }
      } catch (_) {
        _restoreError = 'تعذر التحقق من التوكن المحفوظ';
      } finally {
        if (!handedOff) service.close();
      }
    } catch (_) {
      // Unreadable secure storage: fall through to the token screen.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _forgetToken() async {
    try {
      await const TokenStore().clear();
    } catch (_) {}
  }

  Future<void> _useAnotherToken() async {
    await _forgetToken();
    if (!mounted) return;
    setState(() {
      _restoreError = null;
      _tokenNotice = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final session = _session;
    final service = _service;
    if (session == null || service == null) {
      final restoreError = _restoreError;
      if (restoreError != null) {
        return _RestoreErrorView(
          message: restoreError,
          onRetry: _retry,
          onUseAnotherToken: _useAnotherToken,
        );
      }
      return TokenScreen(
        onAuthenticated: _setSession,
        notice: _tokenNotice,
      );
    }
    return CreateRepoScreen(
      service: service,
      user: session.user,
      onSignedOut: _signedOut,
    );
  }
}

/// Shown when the saved token could not be verified (offline, GitHub down…).
class _RestoreErrorView extends StatelessWidget {
  const _RestoreErrorView({
    required this.message,
    required this.onRetry,
    required this.onUseAnotherToken,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onUseAnotherToken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off, size: 48),
                const SizedBox(height: 16),
                Text(
                  'تعذر التحقق من حسابك',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  'توكنك المحفوظ لم يُمسح.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
                TextButton(
                  onPressed: onUseAnotherToken,
                  child: const Text('استخدام توكن آخر'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
