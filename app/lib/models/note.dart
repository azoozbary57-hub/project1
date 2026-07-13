class Note {
  final String id;
  final String title;
  final String body;
  final int updatedAt; // epoch millis, used for last-write-wins merges
  final bool deleted; // tombstone, kept so deletions propagate to other devices

  const Note({
    required this.id,
    required this.title,
    required this.body,
    required this.updatedAt,
    this.deleted = false,
  });

  Note copyWith({
    String? title,
    String? body,
    int? updatedAt,
    bool? deleted,
  }) {
    return Note(
      id: id,
      title: title ?? this.title,
      body: body ?? this.body,
      updatedAt: updatedAt ?? this.updatedAt,
      deleted: deleted ?? this.deleted,
    );
  }

  Map<String, Object?> toDbMap() {
    return {
      'id': id,
      'title': title,
      'body': body,
      'updated_at': updatedAt,
      'deleted': deleted ? 1 : 0,
    };
  }

  factory Note.fromDbMap(Map<String, Object?> map) {
    return Note(
      id: map['id'] as String,
      title: map['title'] as String,
      body: map['body'] as String,
      updatedAt: map['updated_at'] as int,
      deleted: (map['deleted'] as int) == 1,
    );
  }
}
