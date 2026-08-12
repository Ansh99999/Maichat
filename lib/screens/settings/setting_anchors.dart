/// Stable ids for the individual settings scattered across the detail pages.
///
/// The search on the settings hub deep-links to a page and passes one of these
/// so the destination can scroll the row into view and flash it, the way
/// Android Settings highlights the entry you searched for.
enum SettingAnchor {
  baseUrl,
  apiKey,
  model,
  theme,
  systemColours,
  font,
  chatAvatars,
  textPlacement,
  names,
  messageActions,
  chatColours,
  storage,
  version,
}
