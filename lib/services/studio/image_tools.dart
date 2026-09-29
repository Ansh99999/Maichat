import '../../models/agent_message.dart';
import '../../models/gallery_image.dart';
import 'studio_images.dart';
import 'studio_tools.dart';

/// What the picture tools need from the app, beyond the draft: somewhere to
/// file a picture, the user's gallery, and the web client. A separate
/// interface from [StudioServices] so a test that has no pictures to give
/// need not pretend to; a tool run without it says so plainly.
abstract class StudioPictureServices {
  /// The web client pictures are searched and fetched with.
  StudioImages get images;

  /// Files [picture] in the app's gallery under [characterId] (a file in the
  /// pictures folder, never base64 in storage) and returns the record, or
  /// null when there is nowhere to write it.
  Future<GalleryImage?> fileWebPicture(
    WebPicture picture, {
    required String characterId,
    String title = '',
  });

  /// The user's app gallery, newest first.
  List<GalleryImage> get galleryPictures;
}

/// `search_images`, `set_avatar_from_url`, `list_gallery`,
/// `use_gallery_picture`: finding a picture for the character on the web or
/// in the user's own gallery. Registered into [kStudioTools].
final List<StudioTool> kImageTools = <StudioTool>[
  searchImagesTool,
  setAvatarFromUrlTool,
  listGalleryTool,
  useGalleryPictureTool,
];

/// The picture tools by name — the custom agent types' "pictures" group.
const List<String> kImageToolNames = [
  'search_images',
  'set_avatar_from_url',
  'list_gallery',
  'use_gallery_picture',
];

StudioPictureServices _pictures(StudioToolContext ctx) {
  final services = ctx.services;
  if (services is StudioPictureServices) return services as StudioPictureServices;
  throw StudioToolError('Pictures cannot be fetched here.');
}

String _arg(Map<String, dynamic> args, String key, {bool required = false}) {
  final value = args[key];
  if (value == null || (value is String && value.trim().isEmpty)) {
    if (required) throw StudioToolError('"$key" is required.');
    return '';
  }
  return value.toString().trim();
}

/// Whether a picture becomes the avatar or joins the pool (`as`).
bool _asAvatar(Map<String, dynamic> args) {
  final as = _arg(args, 'as').toLowerCase();
  if (as.isEmpty || as == 'avatar' || as == 'main') return true;
  if (as == 'pool' || as == 'extra') return false;
  throw StudioToolError('"as" is "avatar" (the main picture) or "pool" (an '
      'extra picture to swipe to).');
}

/// Puts [ref] on the character: as the avatar, with the old one kept in the
/// pool (as generate_avatar does), or added to the pool.
void _place(
  StudioToolContext ctx,
  String tool,
  String summary,
  String ref, {
  required bool avatar,
}) {
  ctx.edit(tool, summary, (ws) {
    final c = ws.character;
    if (avatar) {
      c.avatars.remove(ref);
      if (c.hasAvatar && c.avatar != ref && !c.avatars.contains(c.avatar)) {
        c.avatars.add(c.avatar);
      }
      c.avatar = ref;
    } else if (!c.hasAvatar) {
      // A pool with nothing worn: the first picture is worn.
      c.avatar = ref;
    } else if (c.avatar != ref && !c.avatars.contains(ref)) {
      c.avatars.add(ref);
    }
  });
}

const Map<String, dynamic> _asParam = {
  'type': 'string',
  'enum': ['avatar', 'pool'],
  'description': '"avatar" to make it the main picture (the old one joins the '
      'pool), "pool" to add it as an extra picture. Defaults to avatar.',
};

final StudioTool searchImagesTool = StudioTool(
  const ToolSpec(
    name: 'search_images',
    description: 'Searches openly licensed pictures on the web (Openverse by '
        'default, or Wikimedia Commons) and returns numbered candidates with '
        'their creator and licence. Use set_avatar_from_url with a '
        "candidate's url to use one. For art on Pinterest, DeviantArt, "
        'ArtStation and the like, ask the user for a link instead — those sites '
        'cannot be searched here.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {
          'type': 'string',
          'description': 'What the picture shows: "lighthouse at night", '
              '"victorian woman portrait painting".',
        },
        'source': {
          'type': 'string',
          'enum': ['openverse', 'commons'],
        },
      },
      'required': ['query'],
    },
  ),
  (ctx, args) async {
    final pictures = _pictures(ctx);
    final query = _arg(args, 'query', required: true);
    final source = ImageSource.byName(_arg(args, 'source'));
    List<ImageCandidate> found;
    try {
      found = await pictures.images.search(query, source: source);
    } on ImageError catch (e) {
      throw StudioToolError(e.message);
    }
    return StudioToolResult.json({
      'source': source.label,
      if (found.isEmpty)
        'note': 'Nothing found. Try fewer or plainer words, or the other '
            'source.',
      'candidates': [
        for (var i = 0; i < found.length; i++)
          {'n': i + 1, ...found[i].toJson()},
      ],
    });
  },
);

final StudioTool setAvatarFromUrlTool = StudioTool(
  const ToolSpec(
    name: 'set_avatar_from_url',
    description: 'Downloads a picture from the web and gives it to the '
        "character. Takes a picture's own address or the page it is on — a "
        'Pinterest pin, a DeviantArt or ArtStation page, a blog post — and '
        'finds the picture the page shows. The picture is saved in the '
        "user's gallery with where it came from, so the artist stays credited.",
    parameters: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
        'as': _asParam,
      },
      'required': ['url'],
    },
  ),
  (ctx, args) async {
    final pictures = _pictures(ctx);
    final url = _arg(args, 'url', required: true);
    final avatar = _asAvatar(args);
    WebPicture picture;
    try {
      picture = await pictures.images.fetchPicture(url);
    } on ImageError catch (e) {
      throw StudioToolError(e.message);
    }
    final record = await pictures.fileWebPicture(
      picture,
      characterId: ctx.character.id,
    );
    if (record == null) {
      throw StudioToolError('The picture was fetched but there is nowhere on '
          'this device to keep it.');
    }
    final host = Uri.tryParse(picture.source)?.host.replaceFirst('www.', '') ??
        'the web';
    _place(
      ctx,
      'set_avatar_from_url',
      avatar ? 'Set a picture from $host as the avatar' : 'Added a picture from $host',
      record.image,
      avatar: avatar,
    );
    return StudioToolResult.json({
      'ok': true,
      'as': avatar ? 'avatar' : 'pool',
      'picture': record.image,
      'gallery_id': record.id,
      'source': picture.source,
      if (record.credit.isNotEmpty) 'credit': record.credit,
    });
  },
);

final StudioTool listGalleryTool = StudioTool(
  const ToolSpec(
    name: 'list_gallery',
    description: "Lists pictures in the user's own app gallery — ones they "
        'uploaded, generated or saved — with ids for use_gallery_picture. '
        'Pass query to narrow by title or tag.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string'},
      },
    },
  ),
  (ctx, args) async {
    final pictures = _pictures(ctx);
    final query = _arg(args, 'query').toLowerCase();
    final matches = [
      for (final g in pictures.galleryPictures)
        if (query.isEmpty ||
            g.title.toLowerCase().contains(query) ||
            g.tags.any((t) => t.toLowerCase().contains(query)) ||
            g.credit.toLowerCase().contains(query))
          g,
    ];
    return StudioToolResult.json({
      'count': matches.length,
      if (matches.isEmpty)
        'note': query.isEmpty
            ? 'The gallery is empty.'
            : 'No picture matches "$query".',
      'pictures': [
        for (final g in matches.take(40))
          {
            'id': g.id,
            'title': g.displayTitle,
            if (g.tags.isNotEmpty) 'tags': g.tags,
            if (g.characterId == ctx.character.id) 'this_character': true,
            if (g.credit.isNotEmpty) 'credit': g.credit,
            'picture': g.image,
          },
      ],
    });
  },
);

final StudioTool useGalleryPictureTool = StudioTool(
  const ToolSpec(
    name: 'use_gallery_picture',
    description: "Gives the character a picture from the user's gallery, by "
        'its id from list_gallery.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'as': _asParam,
      },
      'required': ['id'],
    },
  ),
  (ctx, args) async {
    final pictures = _pictures(ctx);
    final id = _arg(args, 'id', required: true);
    final avatar = _asAvatar(args);
    final match =
        pictures.galleryPictures.where((g) => g.id == id).firstOrNull;
    if (match == null) {
      throw StudioToolError('No gallery picture has the id "$id". Call '
          'list_gallery for the ids.');
    }
    _place(
      ctx,
      'use_gallery_picture',
      avatar
          ? 'Set "${match.displayTitle}" from the gallery as the avatar'
          : 'Added "${match.displayTitle}" from the gallery',
      match.image,
      avatar: avatar,
    );
    return StudioToolResult.json({
      'ok': true,
      'as': avatar ? 'avatar' : 'pool',
      'picture': match.image,
    });
  },
);
