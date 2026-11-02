import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'models/models.dart';
import 'screens/create_repo_screen.dart';
import 'screens/token_screen.dart';
import 'services/github_service.dart';
import 'services/token_store.dart';

void main() => runApp(const GitHubZipPusherApp());

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

  @override
  void initState() {
    super.initState();
    _restore();
  }

  void _setSession(String token, GitHubUser user) {
    setState(() {
      _session = Session(token: token, user: user);
      _service = GitHubService(token: token);
    });
  }

  Future<void> _restore() async {
    final token = await const TokenStore().read();
    if (token != null && token.isNotEmpty) {
      try {
        final user = await GitHubService(token: token).currentUser();
        if (!mounted) return;
        _setSession(token, user);
        setState(() => _loading = false);
        return;
      } catch (_) {
        // Expired or revoked: fall through to the token screen.
      }
    }
    if (!mounted) return;
    setState(() => _loading = false);
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
      return TokenScreen(onAuthenticated: _setSession);
    }
    return CreateRepoScreen(
      service: service,
      user: session.user,
      onSignedOut: () => setState(() {
        _session = null;
        _service = null;
      }),
    );
  }
}
