/// The Backups feature's own small models: how often a backup is taken, where
/// it goes, what a finished one turned out to contain, and the record kept
/// afterwards so the Backups screen can list and search what was exported.
///
/// Deliberately free of Flutter: the icons and colours these map to live in the
/// screens, and the archive itself is built by `services/backup_codec.dart`.
library;

/// Told how far along a long read or write is: [done] of [total] pieces, and
/// what is being handled right now.
///
/// A backup can hold thousands of files, and a screen that says nothing while it
/// works looks like a screen that has hung — which is exactly what the first
/// version looked like. Both the archive reader and the foreign-backup reader
/// report through this.
typedef BackupProgress = void Function(int done, int total, String what);

/// How often an automatic backup is taken. There is no background worker on
/// Android here, so "automatic" means *checked when the app opens* — see
/// [BackupPrefs.dueAt] and `AppState.runDueBackup`.
enum BackupSchedule {
  off,
  daily,
  weekly,
  monthly;

  String get label => switch (this) {
        BackupSchedule.off => 'Only when I ask',
        BackupSchedule.daily => 'Every day',
        BackupSchedule.weekly => 'Every week',
        BackupSchedule.monthly => 'Every month',
      };

  /// What the schedule promises, spelled out — the app has to be opened for a
  /// backup to happen, and saying so is better than a backup that never came.
  String get detail => switch (this) {
        BackupSchedule.off => 'Nothing is exported unless you export it',
        BackupSchedule.daily =>
          'Taken when you open the app, if a day has passed',
        BackupSchedule.weekly =>
          'Taken when you open the app, if a week has passed',
        BackupSchedule.monthly =>
          'Taken when you open the app, if a month has passed',
      };

  /// How long between automatic backups, or null when there are none.
  Duration? get every => switch (this) {
        BackupSchedule.off => null,
        BackupSchedule.daily => const Duration(days: 1),
        BackupSchedule.weekly => const Duration(days: 7),
        BackupSchedule.monthly => const Duration(days: 30),
      };

  static BackupSchedule byName(String? name) => BackupSchedule.values.firstWhere(
        (s) => s.name == name,
        orElse: () => BackupSchedule.off,
      );
}

/// Where a finished archive is put.
enum BackupDestination {
  /// Written wherever the system save dialog points — a zip file the user keeps.
  file,

  /// Kept in the app's own backups folder. The only destination an automatic
  /// backup can use without a save dialog, and where "Save a copy" reads from.
  device,

  /// Uploaded to the user's Google Drive.
  drive;

  String get label => switch (this) {
        BackupDestination.file => 'This device (saved file)',
        BackupDestination.device => 'In the app',
        BackupDestination.drive => 'Google Drive',
      };

  static BackupDestination byName(String? name) =>
      BackupDestination.values.firstWhere(
        (d) => d.name == name,
        orElse: () => BackupDestination.device,
      );
}
/// What the app needs to keep talking to one Google Drive account.
///
/// The client id and secret come from the user's own Google Cloud project (a
/// "Desktop app" OAuth client), which is what keeps this simple: there is no
/// server here to hold a secret, and a desktop client's secret is not treated
/// as confidential by the OAuth spec. Only the refresh token is worth guarding,
/// and it lives beside the API keys — app-private, unencrypted, exactly as
/// documented for everything else in this store.
class DriveAuth {
  const DriveAuth({
    this.clientId = '',
    this.clientSecret = '',
    this.refreshToken = '',
    this.email = '',
    this.folderId = '',
  });

  final String clientId;
  final String clientSecret;

  /// The long-lived grant. Its presence *is* "connected".
  final String refreshToken;

  /// Which account consented, for the UI to show. Empty when Google did not say.
  final String email;

  /// The Drive folder backups are uploaded into, once created.
  final String folderId;

  bool get isConnected => refreshToken.trim().isNotEmpty;

  bool get hasClient =>
      clientId.trim().isNotEmpty && clientSecret.trim().isNotEmpty;

  DriveAuth copyWith({
    String? clientId,
    String? clientSecret,
    String? refreshToken,
    String? email,
    String? folderId,
  }) =>
      DriveAuth(
        clientId: clientId ?? this.clientId,
        clientSecret: clientSecret ?? this.clientSecret,
        refreshToken: refreshToken ?? this.refreshToken,
        email: email ?? this.email,
        folderId: folderId ?? this.folderId,
      );

  Map<String, dynamic> toJson() => {
        if (clientId.isNotEmpty) 'clientId': clientId,
        if (clientSecret.isNotEmpty) 'clientSecret': clientSecret,
        if (refreshToken.isNotEmpty) 'refreshToken': refreshToken,
        if (email.isNotEmpty) 'email': email,
        if (folderId.isNotEmpty) 'folderId': folderId,
      };

  factory DriveAuth.fromJson(Map<String, dynamic> json) => DriveAuth(
        clientId: json['clientId'] as String? ?? '',
        clientSecret: json['clientSecret'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        email: json['email'] as String? ?? '',
        folderId: json['folderId'] as String? ?? '',
      );
}
/// The export settings: schedule, where an automatic backup goes, what goes in
/// one, and how many to keep. Its own tiny store entry (`backupPrefs`), never
/// part of a backup itself — see `kBackupExcludedKeys`.
class BackupPrefs {
  const BackupPrefs({
    this.schedule = BackupSchedule.off,
    this.autoDestination = BackupDestination.device,
    this.includeKeys = true,
    this.includePictures = true,
    this.includeVectors = true,
    this.keep = 5,
    this.lastRunAt,
    this.drive = const DriveAuth(),
  });

  final BackupSchedule schedule;

  /// Where an automatic backup is written. Only [BackupDestination.device] and
  /// [BackupDestination.drive] can run without the user in front of a dialog.
  final BackupDestination autoDestination;

  /// Whether provider API keys are written into the archive in plain text. On by
  /// default, because a restore that leaves the app unable to send is not a
  /// restore; a backup with this off leaves the live keys alone on the way back.
  final bool includeKeys;

  /// Whether avatars, gallery pictures and chat backgrounds ride along. Off
  /// makes a much smaller file that restores a chat's *text* exactly and leaves
  /// its pictures missing.
  final bool includePictures;

  /// Whether embedding vectors ride along. Off keeps the documents and lorebooks
  /// but makes semantic recall rebuild them on demand.
  final bool includeVectors;

  /// How many backups to keep per destination before the oldest is dropped.
  final int keep;

  final DateTime? lastRunAt;
  final DriveAuth drive;

  bool get automatic => schedule != BackupSchedule.off;

  /// Whether an automatic backup is owed at [now]. False when the schedule is
  /// off, or when the destination is Drive and Drive is not connected — a
  /// backup that cannot be delivered is not due.
  bool dueAt(DateTime now) {
    final every = schedule.every;
    if (every == null) return false;
    if (autoDestination == BackupDestination.drive && !drive.isConnected) {
      return false;
    }
    final last = lastRunAt;
    if (last == null) return true;
    return !now.isBefore(last.add(every));
  }

  BackupPrefs copyWith({
    BackupSchedule? schedule,
    BackupDestination? autoDestination,
    bool? includeKeys,
    bool? includePictures,
    bool? includeVectors,
    int? keep,
    DateTime? lastRunAt,
    DriveAuth? drive,
  }) =>
      BackupPrefs(
        schedule: schedule ?? this.schedule,
        autoDestination: autoDestination ?? this.autoDestination,
        includeKeys: includeKeys ?? this.includeKeys,
        includePictures: includePictures ?? this.includePictures,
        includeVectors: includeVectors ?? this.includeVectors,
        keep: keep ?? this.keep,
        lastRunAt: lastRunAt ?? this.lastRunAt,
        drive: drive ?? this.drive,
      );

  Map<String, dynamic> toJson() => {
        'schedule': schedule.name,
        'autoDestination': autoDestination.name,
        'includeKeys': includeKeys,
        'includePictures': includePictures,
        'includeVectors': includeVectors,
        'keep': keep,
        if (lastRunAt != null) 'lastRunAt': lastRunAt!.toIso8601String(),
        if (drive.toJson().isNotEmpty) 'drive': drive.toJson(),
      };

  factory BackupPrefs.fromJson(Map<String, dynamic> json) => BackupPrefs(
        schedule: BackupSchedule.byName(json['schedule'] as String?),
        autoDestination:
            BackupDestination.byName(json['autoDestination'] as String?),
        includeKeys: json['includeKeys'] as bool? ?? true,
        includePictures: json['includePictures'] as bool? ?? true,
        includeVectors: json['includeVectors'] as bool? ?? true,
        keep: (json['keep'] as num?)?.toInt() ?? 5,
        lastRunAt: DateTime.tryParse(json['lastRunAt'] as String? ?? ''),
        drive: json['drive'] is Map<String, dynamic>
            ? DriveAuth.fromJson(json['drive'] as Map<String, dynamic>)
            : const DriveAuth(),
      );
}
/// What a backup turned out to hold. Counted from the archive itself rather
/// than tracked as it is built, so the number on a record is the number a
/// restore will actually put back.
class BackupCounts {
  const BackupCounts({
    this.characters = 0,
    this.chats = 0,
    this.messages = 0,
    this.presets = 0,
    this.lorebooks = 0,
    this.scenarios = 0,
    this.documents = 0,
    this.gallery = 0,
    this.providers = 0,
    this.pictures = 0,
    this.vectors = 0,
  });

  final int characters;
  final int chats;
  final int messages;
  final int presets;
  final int lorebooks;
  final int scenarios;
  final int documents;
  final int gallery;
  final int providers;
  final int pictures;
  final int vectors;

  /// Every count, in the order the UI lists them.
  List<(String, int)> get parts => <(String, int)>[
        ('characters', characters),
        ('chats', chats),
        ('messages', messages),
        ('presets', presets),
        ('lorebooks', lorebooks),
        ('scenarios', scenarios),
        ('documents', documents),
        ('gallery pictures', gallery),
        ('providers', providers),
        ('pictures', pictures),
        ('vector sets', vectors),
      ];

  bool get isEmpty => parts.every((p) => p.$2 == 0);

  /// A one-line "12 characters · 30 chats · 900 messages" for a list row, using
  /// only the [limit] largest things that are actually there.
  String summary({int limit = 3}) {
    final present = parts.where((p) => p.$2 > 0).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    if (present.isEmpty) return 'Nothing in it';
    return present
        .take(limit)
        .map((p) => '${p.$2} ${p.$2 == 1 ? _singular(p.$1) : p.$1}')
        .join(' · ');
  }

  static String _singular(String plural) => switch (plural) {
        'gallery pictures' => 'gallery picture',
        'vector sets' => 'vector set',
        _ => plural.endsWith('s')
            ? plural.substring(0, plural.length - 1)
            : plural,
      };

  Map<String, dynamic> toJson() => {
        'characters': characters,
        'chats': chats,
        'messages': messages,
        'presets': presets,
        'lorebooks': lorebooks,
        'scenarios': scenarios,
        'documents': documents,
        'gallery': gallery,
        'providers': providers,
        'pictures': pictures,
        'vectors': vectors,
      };

  factory BackupCounts.fromJson(Map<String, dynamic> json) {
    int at(String key) => (json[key] as num?)?.toInt() ?? 0;
    return BackupCounts(
      characters: at('characters'),
      chats: at('chats'),
      messages: at('messages'),
      presets: at('presets'),
      lorebooks: at('lorebooks'),
      scenarios: at('scenarios'),
      documents: at('documents'),
      gallery: at('gallery'),
      providers: at('providers'),
      pictures: at('pictures'),
      vectors: at('vectors'),
    );
  }
}
/// One export that happened: what it was called, when, how big, where it went
/// and what was in it. The Backups screen's list is these, and its search bar
/// searches [name] (see [matches]).
class BackupRecord {
  const BackupRecord({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.bytes,
    required this.destination,
    this.counts = const BackupCounts(),
    this.path = '',
    this.driveFileId = '',
    this.automatic = false,
    this.appVersion = '',
    this.includesKeys = true,
  });

  final String id;

  /// The archive's file name — the title the search bar matches.
  final String name;
  final DateTime createdAt;
  final int bytes;
  final BackupDestination destination;
  final BackupCounts counts;

  /// Where it landed, when that is knowable: the app-folder path for a
  /// [BackupDestination.device] backup, or whatever the save dialog reported.
  final String path;

  /// The Drive file id, for re-download and for retention to delete it.
  final String driveFileId;

  /// Whether the schedule took it rather than the user.
  final bool automatic;
  final String appVersion;
  final bool includesKeys;

  /// Whether this snapshot can be restored again from where it sits — an
  /// in-app or Drive copy can be, a file handed to the save dialog cannot
  /// (the app has no lasting access to it, only the user does).
  bool get restorable =>
      (destination == BackupDestination.device && path.isNotEmpty) ||
      (destination == BackupDestination.drive && driveFileId.isNotEmpty);

  bool matches(String needle) {
    final n = needle.trim().toLowerCase();
    if (n.isEmpty) return true;
    return name.toLowerCase().contains(n) ||
        destination.label.toLowerCase().contains(n) ||
        counts.summary(limit: 99).toLowerCase().contains(n);
  }

  BackupRecord copyWith({
    String? name,
    int? bytes,
    BackupDestination? destination,
    BackupCounts? counts,
    String? path,
    String? driveFileId,
  }) =>
      BackupRecord(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        bytes: bytes ?? this.bytes,
        destination: destination ?? this.destination,
        counts: counts ?? this.counts,
        path: path ?? this.path,
        driveFileId: driveFileId ?? this.driveFileId,
        automatic: automatic,
        appVersion: appVersion,
        includesKeys: includesKeys,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'bytes': bytes,
        'destination': destination.name,
        'counts': counts.toJson(),
        if (path.isNotEmpty) 'path': path,
        if (driveFileId.isNotEmpty) 'driveFileId': driveFileId,
        if (automatic) 'automatic': true,
        if (appVersion.isNotEmpty) 'appVersion': appVersion,
        'includesKeys': includesKeys,
      };

  factory BackupRecord.fromJson(Map<String, dynamic> json) => BackupRecord(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Backup',
        createdAt:
            DateTime.tryParse(json['createdAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        destination: BackupDestination.byName(json['destination'] as String?),
        counts: json['counts'] is Map<String, dynamic>
            ? BackupCounts.fromJson(json['counts'] as Map<String, dynamic>)
            : const BackupCounts(),
        path: json['path'] as String? ?? '',
        driveFileId: json['driveFileId'] as String? ?? '',
        automatic: json['automatic'] as bool? ?? false,
        appVersion: json['appVersion'] as String? ?? '',
        includesKeys: json['includesKeys'] as bool? ?? true,
      );
}
/// The statistics block on the Backups screen, derived from the records rather
/// than tracked separately — one place to be wrong, and it cannot drift.
class BackupStats {
  const BackupStats({
    required this.count,
    required this.totalBytes,
    required this.largestBytes,
    required this.newest,
    required this.oldest,
    required this.byDestination,
    required this.automatic,
    required this.messages,
  });

  final int count;
  final int totalBytes;
  final int largestBytes;
  final DateTime? newest;
  final DateTime? oldest;

  /// How many backups went to each destination — only the ones that were used.
  final Map<BackupDestination, int> byDestination;

  /// How many of them the schedule took.
  final int automatic;

  /// Messages in the most recent snapshot — the number that says most about
  /// what would come back.
  final int messages;

  int get averageBytes => count == 0 ? 0 : totalBytes ~/ count;

  factory BackupStats.from(List<BackupRecord> records) {
    if (records.isEmpty) {
      return const BackupStats(
        count: 0,
        totalBytes: 0,
        largestBytes: 0,
        newest: null,
        oldest: null,
        byDestination: <BackupDestination, int>{},
        automatic: 0,
        messages: 0,
      );
    }
    final sorted = records.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final byDestination = <BackupDestination, int>{};
    var total = 0;
    var largest = 0;
    var automatic = 0;
    for (final record in records) {
      total += record.bytes;
      if (record.bytes > largest) largest = record.bytes;
      if (record.automatic) automatic++;
      byDestination[record.destination] =
          (byDestination[record.destination] ?? 0) + 1;
    }
    return BackupStats(
      count: records.length,
      totalBytes: total,
      largestBytes: largest,
      newest: sorted.first.createdAt,
      oldest: sorted.last.createdAt,
      byDestination: byDestination,
      automatic: automatic,
      messages: sorted.first.counts.messages,
    );
  }
}
