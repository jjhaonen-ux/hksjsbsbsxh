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

class GitHubService {
  GitHubService({required String token, Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: 'https://api.github.com',
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 60),
                sendTimeout: const Duration(minutes: 3),
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
  bool Function() _isCancelled = () => false;

  // ---------------------------------------------------------------- user

  Future<GitHubUser> currentUser() async {
    final res = await _request(() => _dio.get('/user'));
    final scopesHeader = res.headers.value('x-oauth-scopes') ?? '';
    final scopes = scopesHeader
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return GitHubUser.fromJson(
      res.data as Map<String, dynamic>,
      scopes: scopes,
    );
  }

  // ------------------------------------------------------------- repo

  Future<CreatedRepo> createRepo({
    required String name,
    required bool isPrivate,
    String description = '',
  }) async {
    final res = await _request(
      () => _dio.post(
        '/user/repos',
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
  }

  Future<void> deleteRepo(String owner, String repo) async {
    await _request(() => _dio.delete('/repos/$owner/$repo'));
  }

  // ------------------------------------------------------------- push

  /// Uploads [files] into a single commit on [branch].
  ///
  /// Works both on an empty repository (creates the ref) and on one that
  /// already has history (adds a commit on top of the current head).
  Future<PushResult> pushFiles({
    required String owner,
    required String repo,
    required List<ExtractedFile> files,
    required String branch,
    String commitMessage = 'Import project from ZIP',
    int concurrency = 5,
    void Function(PushProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (files.isEmpty) {
      throw GitHubApiException(
        statusCode: 0,
        message: 'لا توجد ملفات للرفع',
      );
    }

    _isCancelled = isCancelled ?? () => false;

    void report(PushStage stage, int done, int total, [String? detail]) {
      onProgress?.call(PushProgress(
        stage: stage,
        done: done,
        total: total,
        detail: detail,
      ));
    }

    report(PushStage.preparing, 0, files.length, 'قراءة حالة الفرع $branch');

    // 1) Where does the branch currently point? null means empty repo.
    var headSha = await _readBranchHead(owner, repo, branch);

    // The Git Data API refuses to work on a repository with no commits
    // (409 "Git Repository is empty"), so create a first commit through the
    // Contents API. Its tree is NOT reused below, so the placeholder file
    // does not end up in the final tree.
    var bootstrapped = false;
    if (headSha == null) {
      report(PushStage.preparing, 0, files.length, 'تهيئة المستودع الفارغ');
      headSha = await _bootstrapEmptyRepo(owner, repo);
      bootstrapped = true;
    }

    // 2) If the repo already had history, reuse its tree so untouched files
    //    survive.
    String? baseTreeSha;
    if (!bootstrapped) {
      final res = await _request(
        () => _dio.get('/repos/$owner/$repo/git/commits/$headSha'),
      );
      baseTreeSha = ((res.data as Map)['tree'] as Map)['sha'] as String;
    }

    // 3) Upload one blob per file, with a small worker pool.
    final shas = List<String?>.filled(files.length, null);
    var nextIndex = 0;
    var completed = 0;
    var stopped = false;
    Object? firstError;

    Future<void> worker() async {
      while (true) {
        if (stopped) return;
        if (_isCancelled()) {
          stopped = true;
          firstError ??= PushCancelled();
          return;
        }
        final index = nextIndex++;
        if (index >= files.length) return;
        try {
          shas[index] = await _uploadBlob(owner, repo, files[index]);
          completed++;
          report(PushStage.blobs, completed, files.length,
              files[index].relativePath);
        } catch (error) {
          firstError ??= error;
          stopped = true;
          return;
        }
      }
    }

    final workers = concurrency < 1 ? 1 : concurrency;
    await Future.wait(List.generate(workers, (_) => worker()));
    if (firstError != null) throw firstError!;

    // 4) Build the tree in a single request.
    report(PushStage.tree, files.length, files.length, 'بناء الشجرة');
    final treeEntries = <Map<String, dynamic>>[];
    for (var i = 0; i < files.length; i++) {
      treeEntries.add({
        'path': files[i].relativePath,
        'mode': '100644',
        'type': 'blob',
        'sha': shas[i],
      });
    }

    final treeRes = await _request(
      () => _dio.post(
        '/repos/$owner/$repo/git/trees',
        data: {
          'tree': treeEntries,
          if (baseTreeSha != null) 'base_tree': baseTreeSha,
        },
      ),
    );
    final treeSha = (treeRes.data as Map)['sha'] as String;

    // 5) Commit.
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
    );
    final commitSha = (commitRes.data as Map)['sha'] as String;
    final commitUrl = (commitRes.data as Map)['html_url'] as String?;

    // 6) Move the branch to the new commit.
    report(PushStage.ref, files.length, files.length, 'تحديث الفرع $branch');
    await _request(
      () => _dio.patch(
        '/repos/$owner/$repo/git/refs/${_refPath(branch)}',
        data: {'sha': commitSha, 'force': false},
      ),
    );

    report(PushStage.finished, files.length, files.length, 'اكتمل الرفع');

    return PushResult(
      commitSha: commitSha,
      commitUrl: commitUrl,
      branch: branch,
      fileCount: files.length,
    );
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
  ) async {
    try {
      final res = await _request(
        () => _dio.get('/repos/$owner/$repo/git/ref/${_refPath(branch)}'),
      );
      final object = (res.data as Map)['object'] as Map;
      return object['sha'] as String;
    } on GitHubApiException catch (e) {
      if (e.statusCode == 404 || e.statusCode == 409) return null;
      rethrow;
    }
  }

  Future<String> _bootstrapEmptyRepo(String owner, String repo) async {
    final res = await _request(
      () => _dio.put(
        '/repos/$owner/$repo/contents/.gitkeep',
        data: {
          'message': 'Initialize repository',
          'content': base64Encode(utf8.encode('\n')),
        },
      ),
    );
    final commit = (res.data as Map)['commit'] as Map;
    return commit['sha'] as String;
  }

  Future<String> _uploadBlob(
    String owner,
    String repo,
    ExtractedFile file,
  ) async {
    if (_isCancelled()) throw PushCancelled();
    final bytes = await File(file.absPath).readAsBytes();
    if (bytes.length > ZipLimits.maxFileBytes) {
      throw GitHubApiException(
        statusCode: 0,
        message: 'الملف ${file.relativePath} يتجاوز حد GitHub '
            '(${ZipLimits.maxFileBytes ~/ (1024 * 1024)} ميغابايت)',
      );
    }
    final res = await _request(
      () => _dio.post(
        '/repos/$owner/$repo/git/blobs',
        data: {
          'content': base64Encode(bytes),
          'encoding': 'base64',
        },
      ),
    );
    return (res.data as Map)['sha'] as String;
  }

  // ------------------------------------------------------- request layer

  Future<Response<T>> _request<T>(
    Future<Response<T>> Function() send, {
    int maxAttempts = 4,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      if (_isCancelled()) throw PushCancelled();
      try {
        final res = await send();
        final status = res.statusCode ?? 0;
        if (status >= 200 && status < 300) return res;

        // 429 / rate-limited 403 arrive as normal responses because of
        // validateStatus, so retry them here.
        if (_statusRetriable(status, res) && attempt < maxAttempts) {
          await Future<void>.delayed(_retryDelay(res, attempt));
          continue;
        }
        // Non-retriable client error: map it.
        throw _mapStatus(status, res.headers, res.data);
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if (!_isRetriable(e, status) || attempt >= maxAttempts) {
          throw _mapDio(e);
        }
        final wait = _retryDelay(e.response, attempt);
        await Future<void>.delayed(wait);
        if (_isCancelled()) throw PushCancelled();
      }
    }
  }

  bool _isRetriable(DioException e, int? status) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      default:
        break;
    }
    if (status == null) return false;
    return _statusRetriable(status, e.response);
  }

  bool _statusRetriable(int status, Response? res) {
    if (status == 408 || status == 429 || status >= 500) return true;
    if (status == 403) return _looksLikeRateLimit(res);
    return false;
  }

  bool _looksLikeRateLimit(Response? res) {
    final headers = res?.headers;
    if (headers == null) return false;
    if (headers.value('retry-after') != null) return true;
    if (headers.value('x-ratelimit-remaining') == '0') return true;
    final data = res?.data;
    if (data is Map && data['message'] is String) {
      return (data['message'] as String).toLowerCase().contains('rate limit');
    }
    return false;
  }

  Duration _retryDelay(Response? res, int attempt) {
    final retryAfter = res?.headers.value('retry-after');
    if (retryAfter != null) {
      final seconds = int.tryParse(retryAfter.trim());
      if (seconds != null && seconds > 0) {
        return Duration(seconds: seconds.clamp(1, 60));
      }
    }
    final reset = res?.headers.value('x-ratelimit-reset');
    if (reset != null && res?.headers.value('x-ratelimit-remaining') == '0') {
      final epoch = int.tryParse(reset.trim());
      if (epoch != null) {
        final until = DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
        final diff = until.difference(DateTime.now());
        if (diff > Duration.zero) {
          return diff > const Duration(seconds: 60)
              ? const Duration(seconds: 60)
              : diff;
        }
      }
    }
    final base = 700 * (1 << (attempt - 1)); // 700, 1400, 2800 ms
    final capped = base > 12000 ? 12000 : base;
    return Duration(milliseconds: capped);
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
        return 'اسم المستودع مكرر أو قيمة غير صالحة';
      default:
        return null;
    }
  }
}
