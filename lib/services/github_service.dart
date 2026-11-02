import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../models/models.dart';
import 'zip_service.dart';

class GitHubApiException implements Exception {
  GitHubApiException({
    required this.statusCode,
    required this.message,
    this.hint,
  });

  final int statusCode;
  final String message;
  final String? hint;

  @override
  String toString() {
    final code = statusCode == 0 ? '' : '($statusCode) ';
    final suffix = hint == null ? '' : ' — $hint';
    return '$code$message$suffix';
  }
}

/// `POST /user/repos` answered 422 because the name is taken. Kept apart from
/// the generic error so the UI can offer to use that repository instead.
class RepoAlreadyExists extends GitHubApiException {
  RepoAlreadyExists({required this.owner, required this.name})
      : super(
          statusCode: 422,
          message: 'يوجد مستودع باسم "$name" لدى $owner بالفعل',
        );

  final String owner;
  final String name;

  String get fullName => '$owner/$name';

  @override
  String toString() => message;
}

/// State that belongs to ONE logical operation (a push, a repo creation…).
///
/// It is deliberately NOT stored on [GitHubService]: the service is shared by
/// every screen, so a cancel flag kept there would leak into later calls
/// (e.g. `createRepo` failing right after a cancelled upload).
class _Op {
  _Op({
    bool Function()? isCancelled,
    this.onNotice,
    this.minGap = Duration.zero,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : isCancelled = isCancelled ?? _never,
        now = now ?? DateTime.now,
        sleep = sleep ?? _realSleep;

  static bool _never() => false;

  static Future<void> _realSleep(Duration d) => Future<void>.delayed(d);

  /// Clock and sleeper. Real ones in the app; tests replace both so that
  /// minutes of rate-limit waiting take no time.
  final DateTime Function() now;
  final Future<void> Function(Duration) sleep;

  final bool Function() isCancelled;

  /// Shown to the user while we are waiting (rate limit countdown…).
  final void Function(String message)? onNotice;

  /// Minimum spacing between mutating requests (GitHub asks for >= 1 s).
  final Duration minGap;

  DateTime _pauseUntil = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextSlot = DateTime.fromMillisecondsSinceEpoch(0);

  void throwIfCancelled() {
    if (isCancelled()) throw PushCancelled();
  }

  /// Makes every worker of this operation wait, not only the one that was
  /// rate limited.
  void pauseFor(Duration duration) {
    final until = now().add(duration);
    if (until.isAfter(_pauseUntil)) _pauseUntil = until;
  }

  /// Waits for a shared pause and for this request's pacing slot.
  Future<void> beforeSend({required bool paced}) async {
    while (true) {
      throwIfCancelled();
      final current = now();
      if (_pauseUntil.isAfter(current)) {
        await wait(
          _pauseUntil.difference(current),
          label: 'بانتظار حد معدل GitHub',
        );
        continue;
      }
      if (paced && minGap > Duration.zero) {
        if (_nextSlot.isAfter(current)) {
          await wait(_nextSlot.difference(current));
          continue;
        }
        _nextSlot = current.add(minGap);
      }
      return;
    }
  }

  /// Cancellable sleep that reports a countdown when [label] is given.
  Future<void> wait(Duration duration, {String? label}) async {
    final end = now().add(duration);
    while (true) {
      throwIfCancelled();
      final remaining = end.difference(now());
      if (remaining <= Duration.zero) return;
      if (label != null) {
        onNotice?.call('$label — ${_format(remaining)}');
      }
      await sleep(
        remaining < const Duration(seconds: 1)
            ? remaining
            : const Duration(seconds: 1),
      );
    }
  }

  static String _format(Duration d) {
    final seconds = d.inSeconds + 1;
    if (seconds >= 90) return '${(seconds / 60).ceil()} د';
    return '$seconds ث';
  }
}

class GitHubService {
  /// [dio], [now] and [sleep] exist for tests (fake HTTP adapter, virtual
  /// clock). The app only passes [token].
  GitHubService({
    required String token,
    Dio? dio,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
  })  : _now = now ?? DateTime.now,
        _sleep = sleep ?? _Op._realSleep,
        _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: 'https://api.github.com',
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 60),
                // A 100 MB blob on a slow mobile uplink needs minutes.
                sendTimeout: const Duration(minutes: 10),
                headers: {
                  'Authorization': 'Bearer $token',
                  'Accept': 'application/vnd.github+json',
                  'X-GitHub-Api-Version': '2022-11-28',
                  'User-Agent': 'github-zip-pusher/1.0',
                },
                // We handle non-2xx ourselves so we can map every status.
                validateStatus: (status) => status != null && status < 500,
                responseType: ResponseType.json,
              ),
            );

  final Dio _dio;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _sleep;

  _Op _newOp({
    bool Function()? isCancelled,
    void Function(String message)? onNotice,
    Duration minGap = Duration.zero,
  }) =>
      _Op(
        isCancelled: isCancelled,
        onNotice: onNotice,
        minGap: minGap,
        now: _now,
        sleep: _sleep,
      );

  /// Releases the HTTP client. Call it when the session ends; requests that
  /// are already running are allowed to finish.
  void close() => _dio.close();

  /// Text files up to this size travel inside the tree request itself instead
  /// of costing one `POST /git/blobs` each (GitHub allows ~80 content
  /// creating requests per minute and ~500 per hour).
  static const int _inlineMaxBytes = 256 * 1024;

  /// Budget for one `POST /git/trees` body (GitHub documents a 7 MB ceiling).
  static const int _treeBatchBytes = 2 * 1024 * 1024;
  static const int _treeBatchEntries = 1000;

  /// Never wait longer than this for a rate limit inside the app; beyond it
  /// we stop and tell the user when to retry.
  static const Duration _maxAutoWait = Duration(minutes: 10);

  static const String _workflowHint =
      'يحتوي الأرشيف ملفات داخل .github/workflows، وترفضها GitHub بتوكن بلا '
      'نطاق workflow (كلاسيكي) أو صلاحية Workflows (Fine-grained)، وقد '
      'تُرجع رسالة مضللة مثل 404. أضف الصلاحية أو استبعد هذه الملفات.';

  // ---------------------------------------------------------------- user

  Future<GitHubUser> currentUser() async {
    final res = await _request(() => _dio.get('/user'));
    // Only classic tokens get this header (even when it is empty);
    // fine-grained tokens never do.
    final scopesHeader = res.headers.value('x-oauth-scopes');
    final scopes = (scopesHeader ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return GitHubUser.fromJson(
      res.data as Map<String, dynamic>,
      scopes: scopes,
      isClassic: scopesHeader != null,
    );
  }

  // ------------------------------------------------------------- repo

  /// Organizations the user belongs to. Optional information: the token may
  /// lack the permission to list them, so callers should treat a failure as
  /// "none".
  Future<List<String>> listOrganizations() async {
    final res = await _request(
      () => _dio.get('/user/orgs', queryParameters: {'per_page': 100}),
    );
    final data = res.data;
    if (data is! List) return const [];
    return [
      for (final org in data)
        if (org is Map && org['login'] is String) org['login'] as String,
    ];
  }

  /// Creates a repository for the user, or for [owner] when
  /// [asOrganization] is true. A name that is already taken is reported as
  /// [RepoAlreadyExists].
  Future<CreatedRepo> createRepo({
    required String owner,
    required bool asOrganization,
    required String name,
    required bool isPrivate,
    String description = '',
  }) async {
    final path = asOrganization
        ? '/orgs/${Uri.encodeComponent(owner)}/repos'
        : '/user/repos';
    try {
      final res = await _request(
        () => _dio.post(
          path,
          data: {
            'name': name,
            'private': isPrivate,
            'description': description,
            'auto_init': false,
            'has_issues': true,
            'has_wiki': false,
            'has_projects': false,
          },
        ),
      );
      return CreatedRepo.fromJson(res.data as Map<String, dynamic>);
    } on GitHubApiException catch (e) {
      if (e.statusCode == 422 &&
          e.message.toLowerCase().contains('already exists')) {
        throw RepoAlreadyExists(owner: owner, name: name);
      }
      rethrow;
    }
  }

  /// Looks up a repository the user wants to push into and checks that the
  /// push can work, so that the problem shows up now rather than at the last
  /// step of an upload.
  Future<CreatedRepo> getRepo(String owner, String name) async {
    final res = await _request(
      () => _dio.get(
        '/repos/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(name)}',
      ),
    );
    final data = res.data as Map<String, dynamic>;
    if (data['archived'] == true) {
      throw GitHubApiException(
        statusCode: 0,
        message: 'المستودع مؤرشف (للقراءة فقط)',
        hint: 'ألغِ الأرشفة من إعدادات المستودع ثم أعد المحاولة',
      );
    }
    final permissions = data['permissions'];
    if (permissions is Map && permissions['push'] != true) {
      throw GitHubApiException(
        statusCode: 403,
        message: 'لا تملك صلاحية الكتابة في هذا المستودع',
        hint: 'يلزم دور Write أو أعلى في المستودع، وتوكن يشمله',
      );
    }
    return CreatedRepo.fromJson(data);
  }

  /// Deletes a repository. GitHub requires the `delete_repo` scope (classic)
  /// or Administration: write (fine-grained), which a normal upload token
  /// does not have.
  Future<void> deleteRepo(String owner, String repo) async {
    await _request(
      () => _dio.delete(
        '/repos/${Uri.encodeComponent(owner)}/${Uri.encodeComponent(repo)}',
      ),
    );
  }

  // ------------------------------------------------------------- push

  /// Uploads [files] into a single commit on [branch].
  ///
  /// Works both on an empty repository (creates the ref) and on one that
  /// already has history (adds a commit on top of the current head).
  ///
  /// Request budget: small UTF-8 text files are embedded in the tree request,
  /// so only large/binary files cost an individual blob request.
  Future<PushResult> pushFiles({
    required String owner,
    required String repo,
    required List<ExtractedFile> files,
    required String branch,
    String commitMessage = 'Import project from ZIP',
    int concurrency = 2,
    Duration minRequestGap = const Duration(seconds: 1),
    void Function(PushProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (files.isEmpty) {
      throw GitHubApiException(
        statusCode: 0,
        message: 'لا توجد ملفات للرفع',
      );
    }

    var stage = PushStage.preparing;
    var done = 0;
    var total = files.length;

    void report(PushStage s, int d, int t, [String? detail]) {
      stage = s;
      done = d;
      total = t;
      onProgress?.call(PushProgress(
        stage: s,
        done: d,
        total: t,
        detail: detail,
      ));
    }

    final op = _newOp(
      isCancelled: isCancelled,
      minGap: minRequestGap,
      onNotice: (message) => onProgress?.call(PushProgress(
        stage: stage,
        done: done,
        total: total,
        detail: message,
      )),
    );

    report(PushStage.preparing, 0, files.length, 'قراءة حالة الفرع $branch');

    // 1) Where does the branch currently point? null means empty repo.
    var headSha = await _readBranchHead(owner, repo, branch, op);

    // The Git Data API refuses to work on a repository with no commits
    // (409 "Git Repository is empty"), so create a first commit through the
    // Contents API. Its tree is NOT reused below, so the placeholder file
    // does not end up in the final tree.
    var bootstrapped = false;
    if (headSha == null) {
      report(PushStage.preparing, 0, files.length, 'تهيئة المستودع الفارغ');
      headSha = await _bootstrapEmptyRepo(owner, repo, op);
      bootstrapped = true;
    }

    // 2) If the repo already had history, reuse its tree so untouched files
    //    survive.
    String? baseTreeSha;
    if (!bootstrapped) {
      final res = await _request(
        () => _dio.get('/repos/$owner/$repo/git/commits/$headSha'),
        op: op,
      );
      baseTreeSha = ((res.data as Map)['tree'] as Map)['sha'] as String;
    }

    // 3) Decide how each file travels.
    report(PushStage.preparing, 0, files.length, 'فحص الملفات');
    final inlineSet = <int>{}; // small UTF-8 text → inside the tree request
    final emptySet = <int>{}; // zero bytes → one shared empty blob
    final blobIdx = <int>[]; // large or binary → its own blob request
    for (var i = 0; i < files.length; i++) {
      op.throwIfCancelled();
      final f = files[i];
      if (f.size == 0) {
        emptySet.add(i);
      } else if (f.size <= _inlineMaxBytes && await _isInlineText(f.absPath)) {
        inlineSet.add(i);
      } else {
        blobIdx.add(i);
      }
    }

    // 4) Blobs, streamed from disk, with a small worker pool.
    final shas = List<String?>.filled(files.length, null);
    String? emptySha;
    final blobTotal = blobIdx.length + (emptySet.isEmpty ? 0 : 1);
    if (blobTotal > 0) {
      var uploaded = 0;
      report(PushStage.blobs, 0, blobTotal);

      if (emptySet.isNotEmpty) {
        emptySha = await _createEmptyBlob(owner, repo, op);
        uploaded++;
        report(PushStage.blobs, uploaded, blobTotal);
      }

      var nextIndex = 0;
      Object? firstError;

      Future<void> worker() async {
        while (firstError == null) {
          if (op.isCancelled()) {
            firstError ??= PushCancelled();
            return;
          }
          final k = nextIndex++;
          if (k >= blobIdx.length) return;
          final i = blobIdx[k];
          try {
            shas[i] = await _uploadBlob(owner, repo, files[i], op);
            uploaded++;
            report(PushStage.blobs, uploaded, blobTotal, files[i].relativePath);
          } catch (error) {
            firstError ??= error;
            return;
          }
        }
      }

      final workers = concurrency < 1 ? 1 : concurrency;
      await Future.wait(List.generate(workers, (_) => worker()));
      if (firstError != null) throw firstError!;
    }

    // 5-7) Tree → commit → ref. A refusal here is where a missing `workflow`
    //      permission shows up, so it gets a dedicated hint.
    final hasWorkflowFiles = files.any((f) => f.isWorkflowFile);
    try {
      // 5) Build the tree. Entries are sent in batches chained through
      //    `base_tree`, so a big project never exceeds the request budget.
      report(PushStage.tree, 0, files.length, 'بناء الشجرة');
      String? currentBase = baseTreeSha;
      var batch = <Map<String, dynamic>>[];
      var batchCost = 0;
      var processed = 0;

      Future<void> flush() async {
        if (batch.isEmpty) return;
        final entries = batch;
        final base = currentBase;
        final res = await _request(
          () => _dio.post(
            '/repos/$owner/$repo/git/trees',
            data: {
              'tree': entries,
              if (base != null) 'base_tree': base,
            },
          ),
          op: op,
          paced: true,
        );
        currentBase = (res.data as Map)['sha'] as String;
        batch = <Map<String, dynamic>>[];
        batchCost = 0;
        report(PushStage.tree, processed, files.length, 'بناء الشجرة');
      }

      for (var i = 0; i < files.length; i++) {
        op.throwIfCancelled();
        final f = files[i];
        final entry = <String, dynamic>{
          'path': f.relativePath,
          'mode': _modeFor(f),
          'type': 'blob',
        };
        var cost = f.relativePath.length + 120;
        if (inlineSet.contains(i)) {
          entry['content'] = utf8.decode(await File(f.absPath).readAsBytes());
          cost += f.size;
        } else if (emptySet.contains(i)) {
          entry['sha'] = emptySha;
        } else {
          entry['sha'] = shas[i];
        }

        if (batch.isNotEmpty &&
            (batchCost + cost > _treeBatchBytes ||
                batch.length >= _treeBatchEntries)) {
          await flush();
        }
        batch.add(entry);
        batchCost += cost;
        processed++;
      }
      await flush();
      final treeSha = currentBase!;

      // 6) Commit.
      report(PushStage.commit, files.length, files.length, 'إنشاء الالتزام');
      final commitRes = await _request(
        () => _dio.post(
          '/repos/$owner/$repo/git/commits',
          data: {
            'message': commitMessage,
            'tree': treeSha,
            'parents': [headSha],
          },
        ),
        op: op,
        paced: true,
      );
      final commitSha = (commitRes.data as Map)['sha'] as String;
      final commitUrl = (commitRes.data as Map)['html_url'] as String?;

      // 7) Move the branch to the new commit.
      report(PushStage.ref, files.length, files.length, 'تحديث الفرع $branch');
      await _request(
        () => _dio.patch(
          '/repos/$owner/$repo/git/refs/${_refPath(branch)}',
          data: {'sha': commitSha, 'force': false},
        ),
        op: op,
        paced: true,
      );

      report(PushStage.finished, files.length, files.length, 'اكتمل الرفع');

      return PushResult(
        commitSha: commitSha,
        commitUrl: commitUrl,
        branch: branch,
        fileCount: files.length,
      );
    } on GitHubApiException catch (e) {
      if (hasWorkflowFiles && const {403, 404, 422}.contains(e.statusCode)) {
        throw GitHubApiException(
          statusCode: e.statusCode,
          message: e.message,
          hint: _workflowHint,
        );
      }
      rethrow;
    }
  }

  /// File mode stored in the tree: executables keep their bit so `gradlew`
  /// and shell scripts work after a `git clone`.
  String _modeFor(ExtractedFile file) =>
      file.executable ? '100755' : '100644';

  /// True for non-empty, valid UTF-8 text without NUL bytes or a BOM. Those
  /// bytes survive a round trip through a JSON string unchanged.
  Future<bool> _isInlineText(String path) async {
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return false;
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return false;
    }
    if (bytes.contains(0)) return false;
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// `heads/<branch>` with each branch segment URL-encoded but slashes kept.
  String _refPath(String branch) =>
      'heads/${branch.split('/').map(Uri.encodeComponent).join('/')}';

  /// Returns the commit SHA the branch points to, or null when the branch
  /// (or the whole repository) does not exist yet. GitHub answers 404 or
  /// 409 ("Git Repository is empty") in that situation.
  Future<String?> _readBranchHead(
    String owner,
    String repo,
    String branch,
    _Op op,
  ) async {
    try {
      final res = await _request(
        () => _dio.get('/repos/$owner/$repo/git/ref/${_refPath(branch)}'),
        op: op,
      );
      final object = (res.data as Map)['object'] as Map;
      return object['sha'] as String;
    } on GitHubApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 409) return null;
      rethrow;
    }
  }

  Future<String> _bootstrapEmptyRepo(String owner, String repo, _Op op) async {
    final res = await _request(
      () => _dio.put(
        '/repos/$owner/$repo/contents/.gitkeep',
        data: {
          'message': 'Initialize repository',
          'content': base64Encode(utf8.encode('\n')),
        },
      ),
      op: op,
      paced: true,
    );
    final commit = (res.data as Map)['commit'] as Map;
    return commit['sha'] as String;
  }

  /// One blob shared by every zero-byte file.
  Future<String> _createEmptyBlob(String owner, String repo, _Op op) async {
    final res = await _request(
      () => _dio.post(
        '/repos/$owner/$repo/git/blobs',
        data: {'content': '', 'encoding': 'utf-8'},
      ),
      op: op,
      paced: true,
    );
    return (res.data as Map)['sha'] as String;
  }

  static final List<int> _blobPrefix =
      utf8.encode('{"encoding":"base64","content":"');
  static final List<int> _blobSuffix = utf8.encode('"}');

  /// JSON body `{"encoding":"base64","content":"<base64>"}` produced on the
  /// fly from the file, so memory stays flat no matter how big the file is
  /// (the old code held the bytes, the base64 string, the JSON string and its
  /// UTF-8 copy at the same time).
  Stream<List<int>> _blobBody(File file) async* {
    yield _blobPrefix;
    var carry = <int>[]; // 0-2 bytes left over so base64 never pads mid-stream
    await for (final chunk in file.openRead()) {
      final data = carry.isEmpty ? chunk : <int>[...carry, ...chunk];
      final usable = data.length - data.length % 3;
      if (usable > 0) {
        yield ascii.encode(base64Encode(data.sublist(0, usable)));
      }
      carry = data.sublist(usable);
    }
    if (carry.isNotEmpty) yield ascii.encode(base64Encode(carry));
    yield _blobSuffix;
  }

  int _blobBodyLength(int fileLength) =>
      _blobPrefix.length + 4 * ((fileLength + 2) ~/ 3) + _blobSuffix.length;

  Future<String> _uploadBlob(
    String owner,
    String repo,
    ExtractedFile file,
    _Op op,
  ) async {
    op.throwIfCancelled();
    final handle = File(file.absPath);
    final length = await handle.length();
    if (length > ZipLimits.maxFileBytes) {
      throw GitHubApiException(
        statusCode: 0,
        message: 'الملف ${file.relativePath} يتجاوز حد GitHub '
            '(${ZipLimits.maxFileBytes ~/ (1024 * 1024)} ميغابايت)',
      );
    }
    final res = await _request(
      // A stream can be consumed once, so every attempt builds a new one.
      () => _dio.post(
        '/repos/$owner/$repo/git/blobs',
        data: _blobBody(handle),
        options: Options(
          contentType: Headers.jsonContentType,
          headers: {Headers.contentLengthHeader: _blobBodyLength(length)},
        ),
      ),
      op: op,
      paced: true,
    );
    return (res.data as Map)['sha'] as String;
  }

  // ------------------------------------------------------- request layer

  /// Sends a request with retries.
  ///
  /// * Rate limits (429, or 403 with rate-limit signals) honour GitHub's
  ///   guidance: wait for `retry-after`, else until `x-ratelimit-reset`, else
  ///   at least a minute. The wait is shared by every worker of [op].
  /// * Transient failures (timeouts, 408, 5xx) use a short exponential
  ///   backoff.
  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() send, {
    _Op? op,
    bool paced = false,
    int maxTransientAttempts = 4,
    int maxRateLimitRetries = 5,
  }) async {
    final ctx = op ?? _newOp();
    var transient = 0;
    var rateLimited = 0;

    while (true) {
      await ctx.beforeSend(paced: paced);

      Response<T>? ok;
      DioException? error;
      try {
        ok = await send();
      } on DioException catch (e) {
        error = e;
      }

      if (ok != null) {
        final code = ok.statusCode ?? 0;
        if (code >= 200 && code < 300) return ok;
      }

      final Response<dynamic>? response = ok ?? error?.response;
      final status = response?.statusCode ?? 0;

      if (response != null && _isRateLimited(status, response)) {
        rateLimited++;
        final wait = _rateLimitWait(response, rateLimited);
        if (rateLimited > maxRateLimitRetries || wait > _maxAutoWait) {
          throw GitHubApiException(
            statusCode: status,
            message: 'تجاوزت حد معدل طلبات GitHub',
            hint: 'أعد المحاولة بعد ${_humanWait(wait)}',
          );
        }
        // The loop's next `beforeSend` does the (cancellable) waiting.
        ctx.pauseFor(wait);
        continue;
      }

      final retriable =
          (error != null && _isTransient(error)) || status == 408 || status >= 500;
      transient++;
      if (retriable && transient < maxTransientAttempts) {
        await ctx.wait(Duration(milliseconds: 700 * (1 << (transient - 1))));
        continue;
      }

      if (response == null) throw _mapDio(error!);
      throw _mapStatus(status, response.headers, response.data);
    }
  }

  bool _isTransient(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      default:
        return false;
    }
  }

  bool _isRateLimited(int status, Response<dynamic> response) {
    if (status == 429) return true;
    if (status != 403) return false;
    final headers = response.headers;
    if (headers.value('retry-after') != null) return true;
    if (headers.value('x-ratelimit-remaining') == '0') return true;
    final data = response.data;
    if (data is Map && data['message'] is String) {
      final message = (data['message'] as String).toLowerCase();
      return message.contains('rate limit') || message.contains('abuse');
    }
    return false;
  }

  /// How long GitHub wants us to stay away.
  Duration _rateLimitWait(Response<dynamic> response, int hits) {
    final headers = response.headers;

    final retryAfter = int.tryParse((headers.value('retry-after') ?? '').trim());
    if (retryAfter != null && retryAfter > 0) {
      return Duration(seconds: retryAfter + 1);
    }

    if (headers.value('x-ratelimit-remaining') == '0') {
      final epoch = int.tryParse((headers.value('x-ratelimit-reset') ?? '').trim());
      if (epoch != null) {
        final reset =
            DateTime.fromMillisecondsSinceEpoch(epoch * 1000, isUtc: true);
        // Compare with the server clock when available: the phone's may be off.
        var serverNow = _now().toUtc();
        final date = headers.value('date');
        if (date != null) {
          try {
            serverNow = HttpDate.parse(date);
          } catch (_) {}
        }
        final diff = reset.difference(serverNow);
        return (diff > Duration.zero ? diff : Duration.zero) +
            const Duration(seconds: 2);
      }
    }

    // Secondary limit without a hint: GitHub says wait at least a minute.
    final factor = hits >= 4 ? 8 : (1 << (hits - 1)); // 1, 2, 4, 8…
    return Duration(seconds: 60 * factor);
  }

  String _humanWait(Duration d) {
    if (d.inSeconds < 90) return '${d.inSeconds} ثانية';
    return '${(d.inSeconds / 60).ceil()} دقيقة';
  }

  GitHubApiException _mapDio(DioException e) {
    final res = e.response;
    if (res == null) {
      return GitHubApiException(
        statusCode: 0,
        message: 'تعذر الاتصال بـ GitHub: ${e.message ?? e.type.name}',
        hint: 'تحقق من الشبكة',
      );
    }
    return _mapStatus(res.statusCode ?? 0, res.headers, res.data);
  }

  GitHubApiException _mapStatus(int status, Headers headers, dynamic data) {
    var message = 'HTTP $status';
    if (data is Map && data['message'] is String) {
      message = data['message'] as String;
      final errors = data['errors'];
      if (errors is List && errors.isNotEmpty) {
        final first = errors.first;
        if (first is Map && first['message'] is String) {
          message = '$message (${first['message']})';
        }
      }
    }
    return GitHubApiException(
      statusCode: status,
      message: message,
      hint: _hintFor(status),
    );
  }

  String? _hintFor(int status) {
    switch (status) {
      case 401:
        return 'التوكن غير صالح أو منتهي الصلاحية';
      case 403:
        return 'صلاحيات ناقصة في التوكن أو تجاوز حد المعدل';
      case 404:
        return 'العنصر غير موجود أو لا تملك صلاحية الوصول إليه';
      case 422:
        return 'رفضت GitHub قيمة في الطلب (مثل اسم أو مسار ملف غير صالح)';
      default:
        return null;
    }
  }
}
