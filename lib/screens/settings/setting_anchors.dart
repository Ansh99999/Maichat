/// Stable ids for the individual settings scattered across the detail pages.
///
/// The search on the settings hub deep-links to a page and passes one of these
/// so the destination can scroll the row into view and flash it, the way
/// Android Settings highlights the entry you searched for.
enum SettingAnchor {
  // Providers now has a section of its own, whose search reaches its own list —
  // so the provider fields no longer need an anchor here. Kept for the pages that
  // still deep-link.
  theme,
  systemColours,
  font,
  chatAvatars,
  textPlacement,
  spacing,
  names,
  messageActions,
  chatColours,
  groupChats,
  storage,
  version,
}
