/// A note kept on the Home screen.
///
/// Notes live in their own store entry (`homeNotes`), never inside the home
/// layout: the layout is rewritten whenever an edit is finished, and a note is
/// rewritten whenever it is typed into — neither should drag the other along.
class HomeNote {
  HomeNote({
    required this.id,
    this.title = '',
    this.body = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String title;
  final String body;
  final DateTime updatedAt;

  bool get isEmpty => title.trim().isEmpty && body.trim().isEmpty;

  /// The title, or the first line of the body when there is none.
  String get heading {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    for (final line in body.split('\n')) {
      if (line.trim().isNotEmpty) return line.trim();
    }
    return '';
  }

  int get wordCount {
    final words = '$title $body'.trim();
    return words.isEmpty ? 0 : words.split(RegExp(r'\s+')).length;
  }

  HomeNote copyWith({String? title, String? body, DateTime? updatedAt}) =>
      HomeNote(
        id: id,
        title: title ?? this.title,
        body: body ?? this.body,
        updatedAt: updatedAt ?? DateTime.now(),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (title.isNotEmpty) 'title': title,
        if (body.isNotEmpty) 'body': body,
        'updatedAt': updatedAt.toIso8601String(),
      };

  static HomeNote? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    return HomeNote(
      id: id,
      title: json['title'] is String ? json['title'] as String : '',
      body: json['body'] is String ? json['body'] as String : '',
      updatedAt: DateTime.tryParse('${json['updatedAt']}'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is HomeNote &&
      other.id == id &&
      other.title == title &&
      other.body == body &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, title, body, updatedAt);
}
