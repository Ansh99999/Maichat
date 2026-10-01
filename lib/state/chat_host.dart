import '../models/character.dart';
import '../models/conversation.dart';
import '../models/lorebook.dart';

export '../models/conversation.dart' show kHostedChatPrefix;

/// A place outside the app's chat list that keeps chats of its own and shows
/// them in the real chat screen — the Character Studio's Playground.
///
/// While a host is attached ([AppState.hostChats]) one of its chats is the
/// *active* chat: the chat screen, the composer and every send, swipe, edit,
/// fork and delete work on it exactly as on any chat, through the same paths.
/// What differs is only where the chats live and who the character is:
///
/// - the chats are the host's ([chats]), never in [AppState.conversations], so
///   they appear in no chat list and never ride in the `conversations` store
///   entry — [save] is how they are kept;
/// - a character or lorebook id resolves to the host's own first
///   ([character], [lorebook]) — the Studio's live draft — which is what makes
///   the chat a chat *with the draft* as it stands, edit by edit.
abstract class ChatHost {
  /// The chats it keeps, newest first. AppState reads and changes them in
  /// place, as it does its own.
  List<Conversation> get chats;

  /// The character [id] means in this host's chats, or null for the roster's.
  Character? character(String id);

  /// The lorebook [id] means in this host's chats, or null for the library's.
  Lorebook? lorebook(String id);

  /// Changes the character [id] means in this host's chats — the avatar
  /// actions of a hosted chat ("set as avatar", "set as default") land here,
  /// on the host's own (the Studio's draft), never on a roster card that
  /// shares its id. Called only for an id [character] answers.
  void editCharacter(String id, String summary, void Function(Character c) change);

  /// A fresh chat, already kept — when the last one is deleted, the host
  /// still has a chat to show.
  Conversation newChat();

  /// [chat] (a branch of one of its chats) joins the host.
  void adopt(Conversation chat);

  /// Drops the chat with [id].
  void remove(String id);

  /// Keeps the chats, after AppState has changed one.
  void save();
}
