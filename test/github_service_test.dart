// اختبارات GitHubService.
//
// * HTTP: HttpClientAdapter وهمي مكتوب يدويًا يُحقن في Dio (بلا حزم mock).
// * الوقت: GitHubService يقبل now/sleep. هنا ساعة افتراضية: كل sleep يقدّم
//   الساعة بمقدار المدة فورًا، فانتظار دقائق يمرّ في ميلي ثوانٍ، ويمكن قياس
//   مدة الانتظار بدقة (clock.elapsed). لا يُستخدم fakeAsync لأن الشيفرة
//   تقرأ DateTime.now() مباشرة وهو لا يتأثر به.
// * عند وجود طلبين متزامنين يتقدّم الوقت الافتراضي من كليهما، فقياس "المدة"
//   دقيق في الاختبارات المتسلسلة فقط؛ اختبار التوازي يتحقق من الترتيب لا المدة.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:github_zip_pusher/models/models.dart';
import 'package:github_zip_pusher/services/github_service.dart';
import 'package:path/path.dart' as p;

// ------------------------------------------------------------ virtual clock

class FakeClock {
  FakeClock(this.start) : _now = start;

  final DateTime start;
  DateTime _now;
  final List<Duration> sleeps = [];

  /// يُستدعى بعد كل sleep (لتغيير حالة الإلغاء مثلًا أثناء الانتظار).
  void Function()? onSleep;

  DateTime now() => _now;

  Duration get elapsed => _now.difference(start);

  Future<void> sleep(Duration d) async {
    sleeps.add(d);
    _now = _now.add(d);
    onSleep?.call();
    // يفسح المجال للعمال المتوازيين كما يفعل sleep حقيقي.
    await Future<void>.delayed(Duration.zero);
  }
}

// ----------------------------------------------------------- fake HTTP layer

class FakeResponse {
  FakeResponse(this.status, {this.body, this.headers = const {}});

  final int status;
  final Object? body;
  final Map<String, String> headers;
}

class RecordedRequest {
  RecordedRequest({
    required this.method,
    required this.path,
    required this.body,
    required this.bodyLength,
    required this.declaredLength,
    required this.at,
  });

  final String method;
  final String path;
  final Object? body;

  /// عدد بايتات الجسم كما وصل فعلًا إلى المحوّل.
  final int bodyLength;

  /// قيمة ترويسة Content-Length التي طلبها الكود (إن وُجدت).
  final int? declaredLength;
  final DateTime at;

  Map<String, dynamic> get json => body as Map<String, dynamic>;
  String get label => '$method $path';
}

typedef FakeHandler = FutureOr<FakeResponse> Function(RecordedRequest request);

class _Route {
  _Route(this.method, this.pattern, this.handler);
  final String method;
  final Pattern pattern;
  final FakeHandler handler;

  bool matches(String m, String path) =>
      m == method &&
      (pattern is String ? pattern == path : pattern.allMatches(path).isNotEmpty);
}

class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.clock);

  final FakeClock clock;
  final List<RecordedRequest> requests = [];
  final List<String> unmatched = [];
  final List<_Route> _routes = [];

  void on(String method, Pattern path, FakeHandler handler) =>
      _routes.add(_Route(method, path, handler));

  List<RecordedRequest> of(String method, Pattern path) => requests
      .where(
        (r) =>
            r.method == method &&
            (path is String ? path == r.path : path.allMatches(r.path).isNotEmpty),
      )
      .toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object? body;
    var length = 0;
    if (requestStream != null) {
      final bytes = BytesBuilder();
      await for (final chunk in requestStream) {
        bytes.add(chunk);
      }
      final raw = bytes.takeBytes();
      length = raw.length;
      if (raw.isNotEmpty) {
        try {
          body = jsonDecode(utf8.decode(raw));
        } catch (_) {
          body = raw;
        }
      }
    }
    final declared = options.headers['content-length'];
    final request = RecordedRequest(
      method: options.method,
      path: options.uri.path,
      body: body,
      bodyLength: length,
      declaredLength: declared == null ? null : int.tryParse('$declared'),
      at: clock.now(),
    );
    requests.add(request);

    // زمن استجابة صفري لكنه يمرّ عبر طابور الأحداث، فيتداخل العمال كالواقع.
    await Future<void>.delayed(Duration.zero);

    FakeResponse? response;
    for (final route in _routes) {
      if (route.matches(request.method, request.path)) {
        response = await route.handler(request);
        break;
      }
    }
    if (response == null) {
      unmatched.add(request.label);
      response = FakeResponse(418, body: {'message': 'UNMATCHED ${request.label}'});
    }
    return ResponseBody.fromString(
      jsonEncode(response.body ?? <String, dynamic>{}),
      response.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        for (final e in response.headers.entries) e.key.toLowerCase(): [e.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _makeDio(FakeAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      baseUrl: 'https://api.github.com',
      // نفس إعداد الإنتاج: كل ما دون 500 يُعالَج يدويًا.
      validateStatus: (status) => status != null && status < 500,
      responseType: ResponseType.json,
    ),
  );
  dio.httpClientAdapter = adapter;
  return dio;
}

class Rig {
  Rig([DateTime? start]) : clock = FakeClock(start ?? DateTime.utc(2026, 1, 1)) {
    adapter = FakeAdapter(clock);
    service = GitHubService(
      token: 'test-token',
      dio: _makeDio(adapter),
      now: clock.now,
      sleep: clock.sleep,
    );
  }

  final FakeClock clock;
  late final FakeAdapter adapter;
  late final GitHubService service;
}

/// يردّ بالاستجابات بالترتيب، ويكرر الأخيرة بعد أن تنتهي القائمة.
FakeHandler sequence(List<FakeResponse> responses) {
  var i = 0;
  return (_) => responses[i < responses.length ? i++ : responses.length - 1];
}

FakeResponse userOk() => FakeResponse(
      200,
      body: {'login': 'octo', 'name': 'Octo'},
      headers: {'x-oauth-scopes': 'repo, workflow'},
    );

FakeResponse limited429({String? retryAfter}) => FakeResponse(
      429,
      body: {'message': 'Too Many Requests'},
      headers: {if (retryAfter != null) 'retry-after': retryAfter},
    );

/// ينتظر (بدورات حلقة الأحداث) حتى يتحقق الشرط؛ يفشل بدل أن يعلَّق إلى الأبد.
Future<void> until(bool Function() condition, {int maxTurns = 200000}) async {
  var turns = 0;
  while (!condition()) {
    if (++turns > maxTurns) throw StateError('انتهت المهلة بانتظار الشرط');
    await Future<void>.delayed(Duration.zero);
  }
}

int epochSeconds(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// خادم Git Data API وهمي لمستودع o/r فيه تاريخ على الفرع main.
class GitServer {
  GitServer(this.adapter) {
    const base = '/repos/o/r';
    adapter
      ..on(
        'GET',
        '$base/git/ref/heads/main',
        (_) => FakeResponse(200, body: {
          'object': {'sha': 'head1'},
        }),
      )
      ..on(
        'GET',
        '$base/git/commits/head1',
        (_) => FakeResponse(200, body: {
          'tree': {'sha': 'base-tree'},
        }),
      )
      ..on('POST', '$base/git/blobs', _blob)
      ..on('POST', '$base/git/trees', _tree)
      ..on('POST', '$base/git/commits', _commit)
      ..on('PATCH', '$base/git/refs/heads/main', _ref);
  }

  final FakeAdapter adapter;

  /// تُعيد null لتمرير الطلب إلى السلوك الافتراضي (نجاح).
  FutureOr<FakeResponse?> Function(RecordedRequest)? blobOverride;
  FutureOr<FakeResponse?> Function(RecordedRequest)? treeOverride;
  FutureOr<FakeResponse?> Function(RecordedRequest)? commitOverride;
  FutureOr<FakeResponse?> Function(RecordedRequest)? refOverride;

  /// "encoding:content" ← sha الذي أُعيد له، لنتحقق أن كل مسار أخذ sha ملفه.
  final Map<String, String> shaByContent = {};
  int _trees = 0;

  List<RecordedRequest> get blobPosts =>
      adapter.of('POST', '/repos/o/r/git/blobs');
  List<RecordedRequest> get treePosts =>
      adapter.of('POST', '/repos/o/r/git/trees');

  Future<FakeResponse> _blob(RecordedRequest r) async {
    final o = await blobOverride?.call(r);
    if (o != null) return o;
    final json = r.json;
    final key = '${json['encoding']}:${json['content']}';
    final sha =
        shaByContent.putIfAbsent(key, () => 'blob-${shaByContent.length + 1}');
    return FakeResponse(201, body: {'sha': sha});
  }

  Future<FakeResponse> _tree(RecordedRequest r) async {
    final o = await treeOverride?.call(r);
    if (o != null) return o;
    return FakeResponse(201, body: {'sha': 'tree-${++_trees}'});
  }

  Future<FakeResponse> _commit(RecordedRequest r) async {
    final o = await commitOverride?.call(r);
    if (o != null) return o;
    return FakeResponse(201, body: {
      'sha': 'commit-1',
      'html_url': 'https://github.com/o/r/commit/commit-1',
    });
  }

  Future<FakeResponse> _ref(RecordedRequest r) async {
    final o = await refOverride?.call(r);
    if (o != null) return o;
    return FakeResponse(200, body: {'ref': 'refs/heads/main'});
  }
}

List<Map<String, dynamic>> treeEntries(RecordedRequest r) =>
    (r.json['tree'] as List).cast<Map<String, dynamic>>();

// -------------------------------------------------------------- test files

void main() {
  late Directory tmp;
  late Rig rig;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('github_service_test_');
    rig = Rig();
  });

  tearDown(() {
    expect(rig.adapter.unmatched, isEmpty, reason: 'طلبات بلا مسار وهمي');
    rig.service.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ExtractedFile makeFile(
    String rel,
    List<int> bytes, {
    bool executable = false,
  }) {
    final f = File(p.joinAll([tmp.path, ...rel.split('/')]));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return ExtractedFile(
      absPath: f.path,
      relativePath: rel,
      size: bytes.length,
      executable: executable,
    );
  }

  ExtractedFile textFile(String rel, String text, {bool executable = false}) =>
      makeFile(rel, utf8.encode(text), executable: executable);

  ExtractedFile binFile(String rel, [int seed = 1]) =>
      makeFile(rel, [0, seed, 2, 3, 4]);

  Future<PushResult> push(
    List<ExtractedFile> files, {
    bool Function()? isCancelled,
    int concurrency = 2,
    void Function(PushProgress)? onProgress,
  }) =>
      rig.service.pushFiles(
        owner: 'o',
        repo: 'r',
        files: files,
        branch: 'main',
        minRequestGap: Duration.zero,
        concurrency: concurrency,
        isCancelled: isCancelled,
        onProgress: onProgress,
      );

  Future<GitHubApiException> catchApi(Future<Object?> future) async {
    try {
      await future;
    } on GitHubApiException catch (e) {
      return e;
    }
    fail('لم يُرمَ GitHubApiException');
  }

  // ------------------------------------------------------- rate limiting

  group('انتظار حد المعدل', () {
    test('retry-after: ينتظر القيمة + ثانية ثم ينجح', () async {
      rig.adapter.on('GET', '/user', sequence([
        limited429(retryAfter: '30'),
        userOk(),
      ]));

      final user = await rig.service.currentUser();

      expect(user.login, 'octo');
      expect(rig.clock.elapsed, const Duration(seconds: 31));
      expect(rig.adapter.requests, hasLength(2));
      expect(rig.adapter.requests.last.at.difference(rig.clock.start),
          const Duration(seconds: 31));
    });

    test('403 ومعه retry-after (حد ثانوي) يُعامَل كحد معدل', () async {
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(
          403,
          body: {'message': 'You have exceeded a secondary rate limit'},
          headers: {'retry-after': '10'},
        ),
        userOk(),
      ]));

      await rig.service.currentUser();

      expect(rig.clock.elapsed, const Duration(seconds: 11));
    });

    test('retry-after يتقدم على x-ratelimit-reset', () async {
      final reset = epochSeconds(rig.clock.start) + 500;
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(
          429,
          body: {'message': 'slow down'},
          headers: {
            'retry-after': '30',
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '$reset',
          },
        ),
        userOk(),
      ]));

      await rig.service.currentUser();

      expect(rig.clock.elapsed, const Duration(seconds: 31));
    });

    test('x-ratelimit-reset: ينتظر حتى وقت التصفير + ثانيتين', () async {
      final reset = epochSeconds(rig.clock.start) + 45;
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(
          403,
          body: {'message': 'API rate limit exceeded'},
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '$reset',
          },
        ),
        userOk(),
      ]));

      await rig.service.currentUser();

      expect(rig.clock.elapsed, const Duration(seconds: 47));
    });

    test('x-ratelimit-reset في الماضي: ثانيتان فقط', () async {
      final reset = epochSeconds(rig.clock.start) - 100;
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(
          403,
          body: {'message': 'API rate limit exceeded'},
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '$reset',
          },
        ),
        userOk(),
      ]));

      await rig.service.currentUser();

      expect(rig.clock.elapsed, const Duration(seconds: 2));
    });

    test('x-ratelimit-reset يُقارَن بترويسة date من الخادم لا بساعة الهاتف',
        () async {
      // ساعة الهاتف متقدمة ساعة كاملة عن الخادم.
      final server = DateTime.utc(2026, 1, 1);
      final phoneRig = Rig(DateTime.utc(2026, 1, 1, 1));
      addTearDown(phoneRig.service.close);
      phoneRig.adapter.on('GET', '/user', sequence([
        FakeResponse(
          403,
          body: {'message': 'API rate limit exceeded'},
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '${epochSeconds(server) + 30}',
            'date': HttpDate.format(server),
          },
        ),
        userOk(),
      ]));

      await phoneRig.service.currentUser();

      // لو استُخدمت ساعة الهاتف لكان الانتظار ثانيتين فقط.
      expect(phoneRig.clock.elapsed, const Duration(seconds: 32));
    });

    test('بلا أي ترويسة: دقيقة، ثم تتضاعف عند التكرار', () async {
      rig.adapter.on('GET', '/user', sequence([
        limited429(),
        userOk(),
      ]));
      await rig.service.currentUser();
      expect(rig.clock.elapsed, const Duration(seconds: 60));
    });

    test('بلا ترويسات وتكرر الحد مرتين: 60 ثم 120 ثانية', () async {
      rig.adapter.on('GET', '/user', sequence([
        limited429(),
        limited429(),
        userOk(),
      ]));
      await rig.service.currentUser();
      expect(rig.clock.elapsed, const Duration(seconds: 180));
    });

    test('403 برسالة rate limit وبلا ترويسات يعامل كحد معدل (دقيقة)', () async {
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(403, body: {'message': 'API rate limit exceeded for user'}),
        userOk(),
      ]));
      await rig.service.currentUser();
      expect(rig.clock.elapsed, const Duration(seconds: 60));
    });

    test('يتوقف إن زاد الانتظار عن 10 دقائق، دون أن ينام', () async {
      rig.adapter.on('GET', '/user', sequence([limited429(retryAfter: '700')]));

      final e = await catchApi(rig.service.currentUser());

      expect(e.statusCode, 429);
      expect(e.message, 'تجاوزت حد معدل طلبات GitHub');
      expect(e.hint, contains('12 دقيقة'));
      expect(rig.clock.sleeps, isEmpty);
      expect(rig.adapter.requests, hasLength(1));
    });

    test('الحد الفاصل: 600 ثانية مسموحة و601 لا', () async {
      // retry-after 599 ← انتظار 600 ثانية = 10 دقائق بالضبط (مسموح).
      rig.adapter.on('GET', '/user', sequence([
        limited429(retryAfter: '599'),
        userOk(),
      ]));
      await rig.service.currentUser();
      expect(rig.clock.elapsed, const Duration(minutes: 10));

      // retry-after 600 ← 601 ثانية (يتجاوز) فيتوقف.
      final other = Rig();
      addTearDown(other.service.close);
      other.adapter
          .on('GET', '/user', sequence([limited429(retryAfter: '600')]));
      final e = await catchApi(other.service.currentUser());
      expect(e.statusCode, 429);
      expect(e.hint, contains('11 دقيقة'));
      expect(other.clock.sleeps, isEmpty);
    });

    test('x-ratelimit-reset بعيد (> 10 دقائق) يوقف المحاولة', () async {
      final reset = epochSeconds(rig.clock.start) + 700;
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(
          403,
          body: {'message': 'API rate limit exceeded'},
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '$reset',
          },
        ),
      ]));

      final e = await catchApi(rig.service.currentUser());

      expect(e.statusCode, 403);
      expect(e.message, 'تجاوزت حد معدل طلبات GitHub');
      expect(rig.clock.sleeps, isEmpty);
    });

    test('يستسلم بعد 5 إعادات متتالية: 60+120+240+480+480 ثانية و6 طلبات',
        () async {
      rig.adapter.on('GET', '/user', sequence([limited429()]));

      final e = await catchApi(rig.service.currentUser());

      expect(e.statusCode, 429);
      expect(e.message, 'تجاوزت حد معدل طلبات GitHub');
      expect(rig.adapter.requests, hasLength(6));
      expect(rig.clock.elapsed, const Duration(seconds: 1380));
    });

    test('403 عادي بلا إشارات حد معدل لا يُعاد ولا يُنتظر', () async {
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(403, body: {'message': 'Resource not accessible'}),
      ]));

      final e = await catchApi(rig.service.currentUser());

      expect(e.statusCode, 403);
      expect(rig.adapter.requests, hasLength(1));
      expect(rig.clock.sleeps, isEmpty);
    });
  });

  // ------------------------------------------------------ shared waiting

  group('الانتظار المشترك بين الطلبات المتوازية', () {
    test('بعد أن يُحدَّ عامل واحد لا يرسل العامل الآخر شيئًا حتى ينتهي الانتظار',
        () async {
      final server = GitServer(rig.adapter);
      var calls = 0;
      var limitedReturned = false;
      server.blobOverride = (request) async {
        final n = ++calls;
        if (n == 1) {
          // يبقي الطلب الأول معلقًا حتى يبدأ العامل الآخر طلبه، فيكون الطلبان
          // في الجو معًا في اللحظة نفسها (ترتيب قراءة الملفات من القرص متغيّر).
          await until(() => server.blobPosts.length >= 2);
          limitedReturned = true;
          return limited429(retryAfter: '5');
        }
        if (n == 2) {
          // لا يسلّم رده قبل أن يعالج العامل الأول رد 429 ويُفعّل الإيقاف.
          await until(() => limitedReturned);
          await Future<void>.delayed(Duration.zero);
        }
        return null;
      };
      final details = <String>[];

      final result = await push(
        [binFile('a.bin', 1), binFile('b.bin', 2), binFile('c.bin', 3)],
        concurrency: 2,
        onProgress: (pp) {
          if (pp.detail != null) details.add(pp.detail!);
        },
      );

      expect(result.commitSha, 'commit-1');
      final blobs = server.blobPosts;
      // طلبان أُرسلا معًا؛ الأول رُفض، ثم الإعادة + الملف الثالث بعد الانتظار.
      expect(blobs, hasLength(4));
      final t0 = rig.clock.start;
      expect(blobs[0].at, t0);
      expect(blobs[1].at, t0);
      for (final later in blobs.skip(2)) {
        expect(
          later.at.difference(t0),
          greaterThanOrEqualTo(const Duration(seconds: 6)),
          reason: 'أُرسل طلب قبل انتهاء الانتظار المشترك',
        );
      }
      expect(details.any((d) => d.contains('بانتظار حد معدل GitHub')), isTrue);
    });
  });

  // --------------------------------------------------------- cancellation

  group('الإلغاء خاص بالعملية (البند 1)', () {
    FakeResponse repoCreated() => FakeResponse(201, body: {
          'name': 'new-repo',
          'html_url': 'https://github.com/o/new-repo',
          'default_branch': 'main',
          'private': false,
          'owner': {'login': 'o'},
        });

    test('رفع مُلغى منذ البداية لا يرسل شيئًا، وإنشاء المستودع بعده ينجح',
        () async {
      GitServer(rig.adapter);
      rig.adapter.on('POST', '/user/repos', (_) => repoCreated());

      await expectLater(
        push([textFile('a.txt', 'a')], isCancelled: () => true),
        throwsA(isA<PushCancelled>()),
      );
      expect(rig.adapter.requests, isEmpty);

      final repo = await rig.service.createRepo(
        owner: 'o',
        asOrganization: false,
        name: 'new-repo',
        isPrivate: false,
      );
      expect(repo.fullName, 'o/new-repo');
      expect(repo.defaultBranch, 'main');
    });

    test('إلغاء في منتصف رفع الـ blobs يوقفه، ثم رفع جديد على الخدمة نفسها ينجح',
        () async {
      final server = GitServer(rig.adapter);
      var cancelled = false;
      var blobCalls = 0;
      server.blobOverride = (_) {
        if (++blobCalls == 2) cancelled = true;
        return null;
      };

      await expectLater(
        push(
          [for (var i = 1; i <= 5; i++) binFile('f$i.bin', i)],
          concurrency: 1,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<PushCancelled>()),
      );
      expect(server.blobPosts, hasLength(2));
      expect(server.treePosts, isEmpty);

      // عملية لاحقة على الخدمة نفسها لا تتأثر بالإلغاء السابق.
      server.blobOverride = null;
      final result = await push([textFile('ok.txt', 'ok')]);
      expect(result.fileCount, 1);
      expect(result.commitSha, 'commit-1');
    });

    test('الإلغاء أثناء انتظار حد المعدل يقطع الانتظار فورًا', () async {
      final limited = Rig();
      addTearDown(limited.service.close);
      limited.adapter
        ..on('GET', '/repos/o/r/git/ref/heads/main',
            sequence([limited429(retryAfter: '30')]))
        ..on('POST', '/user/repos', (_) => repoCreated());
      var cancelled = false;
      limited.clock.onSleep = () {
        if (limited.clock.elapsed >= const Duration(seconds: 3)) {
          cancelled = true;
        }
      };

      await expectLater(
        limited.service.pushFiles(
          owner: 'o',
          repo: 'r',
          files: [textFile('a.txt', 'a')],
          branch: 'main',
          minRequestGap: Duration.zero,
          isCancelled: () => cancelled,
        ),
        throwsA(isA<PushCancelled>()),
      );
      expect(limited.clock.elapsed, lessThan(const Duration(seconds: 10)));
      expect(limited.adapter.requests, hasLength(1));

      limited.clock.onSleep = null;
      final repo = await limited.service.createRepo(
        owner: 'o',
        asOrganization: false,
        name: 'new-repo',
        isPrivate: true,
      );
      expect(repo.name, 'new-repo');
    });

    test('عمليتان متزامنتان على الخدمة نفسها: الملغاة لا تُلغي الأخرى', () async {
      final server = GitServer(rig.adapter);
      final cancelledPush =
          push([textFile('x.txt', 'x')], isCancelled: () => true);
      final normalPush = push([textFile('y.txt', 'y')]);

      await expectLater(cancelledPush, throwsA(isA<PushCancelled>()));
      final result = await normalPush;

      expect(result.commitSha, 'commit-1');
      expect(server.treePosts, hasLength(1));
      final paths = treeEntries(server.treePosts.single).map((e) => e['path']);
      expect(paths, ['y.txt']);
    });
  });

  // ------------------------------------------------------------- batching

  group('تجزئة الملفات وطرق رفعها', () {
    test('1001 ملف نصي صغير: طلبا شجرة (1000 + 1) مرتبطان بـ base_tree', () async {
      final server = GitServer(rig.adapter);
      final files = [
        for (var i = 0; i < 1001; i++) textFile('d/f$i.txt', 'file $i\n'),
      ];

      final result = await push(files);

      expect(server.blobPosts, isEmpty);
      final trees = server.treePosts;
      expect(trees, hasLength(2));
      expect(treeEntries(trees[0]), hasLength(1000));
      expect(treeEntries(trees[1]), hasLength(1));
      expect(trees[0].json['base_tree'], 'base-tree');
      expect(trees[1].json['base_tree'], 'tree-1');

      final commit = rig.adapter.of('POST', '/repos/o/r/git/commits').single;
      expect(commit.json['tree'], 'tree-2');
      expect(commit.json['parents'], ['head1']);
      expect(commit.json['message'], 'Import project from ZIP');
      final ref = rig.adapter.of('PATCH', '/repos/o/r/git/refs/heads/main').single;
      expect(ref.json, {'sha': 'commit-1', 'force': false});

      expect(result.fileCount, 1001);
      expect(result.branch, 'main');
      expect(result.commitUrl, 'https://github.com/o/r/commit/commit-1');
    });

    test('ميزانية البايتات: 25 ملفًا × 200KB نصًا ← دفعات 10 + 10 + 5', () async {
      final server = GitServer(rig.adapter);
      final body = '${'a' * (200 * 1024 - 1)}\n';
      final files = [
        for (var i = 0; i < 25; i++)
          textFile('f${i.toString().padLeft(2, '0')}.txt', body),
      ];

      await push(files);

      expect(server.blobPosts, isEmpty);
      final sizes = server.treePosts.map((r) => treeEntries(r).length).toList();
      expect(sizes, [10, 10, 5]);
    });

    test('نص حتى 256KB داخل الشجرة، وما فوقه أو الثنائي blob منفصل بـ sha صحيح',
        () async {
      final server = GitServer(rig.adapter);
      const inlineMax = 256 * 1024;

      final smallText = utf8.encode('مرحبا بالعالم\n');
      final exactText = List<int>.filled(inlineMax, 0x61);
      final overText = List<int>.filled(inlineMax + 1, 0x61);
      final binary = [0, 1, 2, 3, 4];
      final withBom = [0xEF, 0xBB, 0xBF, 0x68, 0x69];
      final badUtf8 = [0x68, 0xC3, 0x28];

      final files = [
        makeFile('small.txt', smallText),
        makeFile('exact.txt', exactText),
        makeFile('over.txt', overText),
        makeFile('bin.dat', binary),
        makeFile('bom.txt', withBom),
        makeFile('latin1.txt', badUtf8),
        makeFile('empty1.txt', const []),
        makeFile('empty2.txt', const []),
      ];

      await push(files);

      // أربعة blobs بـ base64 + blob واحد مشترك للملفين الفارغين.
      final blobs = server.blobPosts;
      expect(blobs, hasLength(5));
      final base64Blobs =
          blobs.where((b) => b.json['encoding'] == 'base64').toList();
      final emptyBlobs =
          blobs.where((b) => b.json['encoding'] == 'utf-8').toList();
      expect(base64Blobs, hasLength(4));
      expect(emptyBlobs, hasLength(1));
      expect(emptyBlobs.single.json['content'], '');

      // المحتوى المُرسل = محتوى الملف بالضبط (يختبر تقطيع البث ومعالجة الباقي).
      expect(
        base64Blobs.map((b) => b.json['content'] as String).toSet(),
        {
          base64Encode(overText),
          base64Encode(binary),
          base64Encode(withBom),
          base64Encode(badUtf8),
        },
      );
      // Content-Length المعلن يطابق حجم الجسم الفعلي.
      for (final b in base64Blobs) {
        expect(b.declaredLength, isNotNull);
        expect(b.declaredLength, b.bodyLength);
      }

      final entries = {
        for (final e in treeEntries(server.treePosts.single)) e['path'] as String: e,
      };
      expect(entries.keys.toSet(), {
        'small.txt', 'exact.txt', 'over.txt', 'bin.dat', 'bom.txt',
        'latin1.txt', 'empty1.txt', 'empty2.txt',
      });

      // نصوص مضمَّنة: content موجود وsha غائب.
      expect(entries['small.txt']!['content'], utf8.decode(smallText));
      expect(entries['small.txt']!.containsKey('sha'), isFalse);
      expect(entries['exact.txt']!['content'], utf8.decode(exactText));
      expect(entries['exact.txt']!.containsKey('sha'), isFalse);

      // blobs: sha الخاص بمحتوى كل ملف (لا اختلاط بين العمال المتوازيين).
      String shaOf(List<int> bytes) =>
          server.shaByContent['base64:${base64Encode(bytes)}']!;
      expect(entries['over.txt']!['sha'], shaOf(overText));
      expect(entries['bin.dat']!['sha'], shaOf(binary));
      expect(entries['bom.txt']!['sha'], shaOf(withBom));
      expect(entries['latin1.txt']!['sha'], shaOf(badUtf8));
      for (final name in ['over.txt', 'bin.dat', 'bom.txt', 'latin1.txt']) {
        expect(entries[name]!.containsKey('content'), isFalse, reason: name);
      }

      // الملفان الفارغان يتشاركان blob واحدًا.
      final emptySha = server.shaByContent['utf-8:'];
      expect(emptySha, isNotNull);
      expect(entries['empty1.txt']!['sha'], emptySha);
      expect(entries['empty2.txt']!['sha'], emptySha);

      for (final e in entries.values) {
        expect(e['type'], 'blob');
        expect(e['mode'], '100644');
      }
    });
  });

  // ---------------------------------------------------------- file modes

  group('صلاحية التنفيذ في الشجرة', () {
    test('الملف التنفيذي 100755 والعادي 100644 (نصي مضمَّن وثنائي blob)', () async {
      final server = GitServer(rig.adapter);
      final files = [
        textFile('gradlew', '#!/bin/sh\necho run\n', executable: true),
        makeFile('bin/tool', [0, 1, 2, 3], executable: true),
        textFile('README.md', '# readme\n'),
        makeFile('data.bin', [0, 9, 9, 9]),
      ];

      await push(files);

      final modes = {
        for (final e in treeEntries(server.treePosts.single))
          e['path'] as String: e['mode'] as String,
      };
      expect(modes, {
        'gradlew': '100755',
        'bin/tool': '100755',
        'README.md': '100644',
        'data.bin': '100644',
      });
    });
  });

  // -------------------------------------------------------- error mapping

  group('تحويل أخطاء HTTP إلى رسائل عربية', () {
    test('401: التوكن غير صالح', () async {
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(401, body: {'message': 'Bad credentials'}),
      ]));

      final e = await catchApi(rig.service.currentUser());

      expect(e.statusCode, 401);
      expect(e.message, 'Bad credentials');
      expect(e.hint, 'التوكن غير صالح أو منتهي الصلاحية');
      expect(
        e.toString(),
        '(401) Bad credentials — التوكن غير صالح أو منتهي الصلاحية',
      );
      expect(rig.adapter.requests, hasLength(1));
    });

    test('403: صلاحيات ناقصة (ليس حد معدل)', () async {
      rig.adapter.on('GET', '/user', sequence([
        FakeResponse(403, body: {
          'message': 'Resource not accessible by personal access token',
        }),
      ]));

      final e = await catchApi(rig.service.currentUser());

      expect(e.statusCode, 403);
      expect(e.hint, 'صلاحيات ناقصة في التوكن أو تجاوز حد المعدل');
    });

    test('404: غير موجود أو لا صلاحية', () async {
      rig.adapter.on('GET', '/repos/o/r', sequence([
        FakeResponse(404, body: {'message': 'Not Found'}),
      ]));

      final e = await catchApi(rig.service.getRepo('o', 'r'));

      expect(e.statusCode, 404);
      expect(e.message, 'Not Found');
      expect(e.hint, 'العنصر غير موجود أو لا تملك صلاحية الوصول إليه');
    });

    test('جسم بلا message: HTTP <الرمز>', () async {
      rig.adapter.on('GET', '/repos/o/r', sequence([FakeResponse(404)]));

      final e = await catchApi(rig.service.getRepo('o', 'r'));

      expect(e.message, 'HTTP 404');
    });

    test('422 عام: يضم أول خطأ تفصيلي ويعطي تلميح الرفض', () async {
      rig.adapter.on('POST', '/user/repos', sequence([
        FakeResponse(422, body: {
          'message': 'Validation Failed',
          'errors': [
            {'message': 'name is too long'},
          ],
        }),
      ]));

      final e = await catchApi(rig.service.createRepo(
        owner: 'o',
        asOrganization: false,
        name: 'r',
        isPrivate: false,
      ));

      expect(e, isNot(isA<RepoAlreadyExists>()));
      expect(e.statusCode, 422);
      expect(e.message, 'Validation Failed (name is too long)');
      expect(e.hint, 'رفضت GitHub قيمة في الطلب (مثل اسم أو مسار ملف غير صالح)');
    });

    test('422 والاسم موجود: RepoAlreadyExists برسالة عربية', () async {
      rig.adapter.on('POST', '/user/repos', sequence([
        FakeResponse(422, body: {
          'message': 'Repository creation failed.',
          'errors': [
            {'message': 'name already exists on this account'},
          ],
        }),
      ]));

      final e = await catchApi(rig.service.createRepo(
        owner: 'o',
        asOrganization: false,
        name: 'r',
        isPrivate: false,
      ));

      expect(e, isA<RepoAlreadyExists>());
      final exists = e as RepoAlreadyExists;
      expect(exists.statusCode, 422);
      expect(exists.fullName, 'o/r');
      expect(exists.message, 'يوجد مستودع باسم "r" لدى o بالفعل');
      expect(exists.toString(), 'يوجد مستودع باسم "r" لدى o بالفعل');
    });

    test('إنشاء مستودع منظمة يستخدم /orgs/<org>/repos', () async {
      rig.adapter.on('POST', '/orgs/acme/repos', (_) => FakeResponse(201, body: {
            'name': 'r',
            'html_url': 'https://github.com/acme/r',
            'default_branch': 'main',
            'owner': {'login': 'acme'},
          }));

      final repo = await rig.service.createRepo(
        owner: 'acme',
        asOrganization: true,
        name: 'r',
        isPrivate: true,
      );

      expect(repo.fullName, 'acme/r');
      final sent = rig.adapter.requests.single.json;
      expect(sent['name'], 'r');
      expect(sent['private'], true);
    });
  });

  group('أخطاء الرفع مع ملفات .github/workflows (البند 3)', () {
    List<ExtractedFile> withWorkflow() => [
          textFile('README.md', '# r\n'),
          textFile('.github/workflows/ci.yml', 'name: ci\n'),
        ];

    for (final status in [403, 404, 422]) {
      test('$status عند بناء الشجرة ← تلميح workflow مع بقاء الرمز والرسالة',
          () async {
        final server = GitServer(rig.adapter);
        server.treeOverride = (_) =>
            FakeResponse(status, body: {'message': 'Server said no'});

        final e = await catchApi(push(withWorkflow()));

        expect(e.statusCode, status);
        expect(e.message, 'Server said no');
        expect(e.hint, contains('workflow'));
        expect(e.hint, contains('.github/workflows'));
      });
    }

    test('404 عند بناء الشجرة بلا ملفات workflow ← التلميح العام لا تلميح workflow',
        () async {
      final server = GitServer(rig.adapter);
      server.treeOverride = (_) => FakeResponse(404, body: {'message': 'Not Found'});

      final e = await catchApi(push([textFile('README.md', '# r\n')]));

      expect(e.statusCode, 404);
      expect(e.hint, 'العنصر غير موجود أو لا تملك صلاحية الوصول إليه');
    });

    test('401 مع ملفات workflow لا يُنسب إلى صلاحية workflow', () async {
      final server = GitServer(rig.adapter);
      server.treeOverride =
          (_) => FakeResponse(401, body: {'message': 'Bad credentials'});

      final e = await catchApi(push(withWorkflow()));

      expect(e.statusCode, 401);
      expect(e.hint, 'التوكن غير صالح أو منتهي الصلاحية');
    });

    test('رفض تحديث الفرع (422) مع ملفات workflow يحمل تلميح workflow أيضًا',
        () async {
      final server = GitServer(rig.adapter);
      server.refOverride =
          (_) => FakeResponse(422, body: {'message': 'Reference update failed'});

      final e = await catchApi(push(withWorkflow()));

      expect(e.statusCode, 422);
      expect(e.hint, contains('workflow'));
    });

    test('ملف workflow النصي يُرسل داخل الشجرة كغيره',
        () async {
      final server = GitServer(rig.adapter);

      await push(withWorkflow());

      final paths =
          treeEntries(server.treePosts.single).map((e) => e['path']).toList();
      expect(paths, containsAll(['README.md', '.github/workflows/ci.yml']));
    });
  });
}
