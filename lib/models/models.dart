class GitHubUser {
  const GitHubUser({
    required this.login,
    this.name,
    this.avatarUrl,
    this.scopes = const [],
    this.isClassic = false,
  });

  final String login;
  final String? name;
  final String? avatarUrl;

  /// OAuth scopes reported by GitHub. Empty for fine-grained tokens, and also
  /// for a classic token that was created without any scope; [isClassic]
  /// tells the two apart.
  final List<String> scopes;

  /// True when GitHub answered with an `x-oauth-scopes` header, which only
  /// classic tokens get. For fine-grained tokens the permissions cannot be
  /// read up front, so nothing is assumed about them.
  final bool isClassic;

  /// Private repositories need the full `repo` scope.
  bool get canCreatePrivate => !isClassic || scopes.contains('repo');

  /// `public_repo` is enough for public repositories.
  bool get canCreatePublic =>
      !isClassic || scopes.contains('repo') || scopes.contains('public_repo');

  /// Without `workflow`, GitHub refuses files under `.github/workflows`.
  bool get canPushWorkflows => !isClassic || scopes.contains('workflow');

  factory GitHubUser.fromJson(
    Map<String, dynamic> json, {
    List<String> scopes = const [],
    bool isClassic = false,
  }) {
    return GitHubUser(
      login: json['login'] as String,
      name: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      scopes: scopes,
      isClassic: isClassic,
    );
  }
}

class CreatedRepo {
  const CreatedRepo({
    required this.owner,
    required this.name,
    required this.htmlUrl,
    required this.defaultBranch,
    this.isPrivate = false,
  });

  final String owner;
  final String name;
  final String htmlUrl;
  final String defaultBranch;
  final bool isPrivate;

  String get fullName => '$owner/$name';

  factory CreatedRepo.fromJson(Map<String, dynamic> json) {
    final owner = json['owner'] as Map<String, dynamic>?;
    return CreatedRepo(
      owner: (owner?['login'] as String?) ?? '',
      name: json['name'] as String,
      htmlUrl: json['html_url'] as String,
      defaultBranch: (json['default_branch'] as String?) ?? 'main',
      isPrivate: (json['private'] as bool?) ?? false,
    );
  }
}

/// A repository named by the user ("owner/repo").
class RepoRef {
  const RepoRef(this.owner, this.name);

  final String owner;
  final String name;

  String get fullName => '$owner/$name';
}

final RegExp _ownerPattern = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$');
final RegExp _repoNamePattern = RegExp(r'^[A-Za-z0-9._-]{1,100}$');

/// GitHub rejects the names `.` and `..` even though they match the character
/// set.
bool isValidRepoName(String name) =>
    _repoNamePattern.hasMatch(name) && name != '.' && name != '..';

/// Understands `owner/repo`, `github.com/owner/repo`, full https URLs
/// (with an optional `.git`, trailing slash or `/tree/main` tail) and the ssh
/// form `git@github.com:owner/repo.git`. Returns null for anything else.
RepoRef? parseRepoRef(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;

  final withoutHost = s
      .replaceFirst(
        RegExp(r'^(https?://)?(www\.)?github\.com/', caseSensitive: false),
        '',
      )
      .replaceFirst(RegExp(r'^git@github\.com:', caseSensitive: false), '');
  final hadHost = withoutHost != s;
  s = withoutHost.replaceFirst(RegExp(r'[?#].*$'), '');

  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  final parts = s.split('/');
  // A pasted page URL (".../owner/repo/tree/main") carries extra segments.
  if (parts.length < 2 || (parts.length > 2 && !hadHost)) return null;

  final owner = parts[0];
  var name = parts[1];
  if (name.toLowerCase().endsWith('.git')) {
    name = name.substring(0, name.length - 4);
  }
  if (!_ownerPattern.hasMatch(owner) || !isValidRepoName(name)) return null;
  return RepoRef(owner, name);
}

/// A single file extracted from the ZIP and written to the temp directory.
class ExtractedFile {
  const ExtractedFile({
    required this.absPath,
    required this.relativePath,
    required this.size,
    this.executable = false,
  });

  final String absPath;

  /// Path inside the repository, always '/' separated, no leading slash.
  final String relativePath;
  final int size;

  /// Stored in the tree as mode 100755 instead of 100644, so `gradlew` and
  /// shell scripts still run after a `git clone`.
  final bool executable;

  /// GitHub only accepts writes under `.github/workflows/` from a token that
  /// carries the `workflow` scope (classic) / Workflows permission
  /// (fine-grained).
  bool get isWorkflowFile => relativePath.startsWith('.github/workflows/');
}

enum PushStage { preparing, blobs, tree, commit, ref, finished }

class PushProgress {
  const PushProgress({
    required this.stage,
    required this.done,
    required this.total,
    this.detail,
  });

  final PushStage stage;
  final int done;
  final int total;
  final String? detail;
}

class PushResult {
  const PushResult({
    required this.commitSha,
    required this.commitUrl,
    required this.branch,
    required this.fileCount,
  });

  final String commitSha;
  final String? commitUrl;
  final String branch;
  final int fileCount;
}

class PushCancelled implements Exception {
  @override
  String toString() => 'تم إلغاء الرفع';
}
