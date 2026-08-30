/// A picture riding along with one chat turn: what the user attached before
/// sending, or a generated picture shared into the thread.
///
/// The bytes are never here. [ref] is a `local:<file>` reference into the
/// pictures directory (or an `http(s)` URL), exactly as `Character.avatar`,
/// `GalleryImage.image` and a chat background hold theirs — pictures are files,
/// because a picture inside the preferences store made the app unopenable once,
/// and an attachment is the largest thing a message could ever carry.
///
/// [data] is the base64 payload a request needs. It is resolved from [ref] on the
/// way to the wire (see `AppState._wireImages`) and is deliberately **not**
/// persisted and not part of equality: it is a transient view of the file, not a
/// property of the attachment.
class MessageImage {
  const MessageImage({
    required this.ref,
    this.mime = 'image/png',
    this.data = '',
  });

  /// A `local:<file>` reference into the pictures directory, or an http(s) URL.
  final String ref;

  /// The media type to declare on the wire. Sniffed from the bytes when the
  /// picture was stored, derived from the reference's extension otherwise.
  final String mime;

  /// Base64 of the file, filled in only for the copy that goes to a provider.
  final String data;

  bool get hasData => data.isNotEmpty;

  /// Whether this picture lives online rather than on the device — the dialects
  /// that accept a URL are handed one instead of inline bytes.
  bool get isUrl {
    final trimmed = ref.trim();
    return trimmed.startsWith('http://') || trimmed.startsWith('https://');
  }

  MessageImage withData(String data) =>
      MessageImage(ref: ref, mime: mime, data: data);

  /// The same attachment with its payload replaced by a note about its size —
  /// for the request preview, which is copyable and must not put a megabyte of
  /// base64 on the clipboard.
  MessageImage elided() => hasData
      ? withData('<${data.length} base64 characters elided>')
      : this;

  Map<String, dynamic> toJson() => {
        'ref': ref,
        if (mime.isNotEmpty) 'mime': mime,
      };

  factory MessageImage.fromJson(Map<String, dynamic> json) {
    final ref = (json['ref'] as String? ?? json['image'] as String? ?? '').trim();
    final mime = (json['mime'] as String? ?? '').trim();
    return MessageImage(
      ref: ref,
      mime: mime.isEmpty ? mimeForRef(ref) : mime,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MessageImage && other.ref == ref && other.mime == mime;

  @override
  int get hashCode => Object.hash(ref, mime);

  @override
  String toString() => 'MessageImage($ref, $mime)';
}

/// Whether [ref] names a picture this app can actually find: a file in its own
/// pictures directory, or a URL.
///
/// A relative path out of another app's data folder is not one. An importer that
/// has the archive to hand resolves such a path into a real file first (see
/// `services/foreign_backup.dart`); anything left unresolved is dropped rather
/// than stored as an attachment that draws a hole.
bool refIsResolvable(String ref) {
  final trimmed = ref.trim();
  return trimmed.startsWith('local:') ||
      trimmed.startsWith('http://') ||
      trimmed.startsWith('https://');
}

/// The media type for a picture reference, from its file extension. Used when a
/// picture is chosen from the gallery, where the bytes are not to hand — a
/// wrong-but-plausible type is far better than none, and every provider sniffs
/// the bytes anyway.
String mimeForRef(String ref) {
  final lower = ref.trim().toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/png';
}

/// The media type for [bytes], sniffed from their magic number. Mirrors
/// `avatarExtensionFor`, which names the file on disk from the same bytes.
String mimeForBytes(List<int> bytes) {
  bool starts(List<int> magic, {int at = 0}) {
    if (bytes.length < at + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[at + i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(const [0xFF, 0xD8, 0xFF])) return 'image/jpeg';
  if (starts(const [0x47, 0x49, 0x46])) return 'image/gif';
  if (starts(const [0x52, 0x49, 0x46, 0x46]) &&
      starts(const [0x57, 0x45, 0x42, 0x50], at: 8)) {
    return 'image/webp';
  }
  return 'image/png';
}
