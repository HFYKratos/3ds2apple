#!/usr/bin/env bash
# library-selfcheck.sh - static checks for the 0.1.3 game-library actions:
#   1) deleting a game from the Home page (long-press a card to open its context
#      menu; the visible "..." menu is gone): the pushed game data (ROM,
#      GameInfo.json, pushed cover), battery saves, instant save states, play
#      history and per-game settings/cover are removed, the bundled AOT title is
#      hidden until the launcher pushes the data again, the second confirmation
#      says that this cannot be undone, and the library / Save Manager update
#      through the shared GameLibrary;
#   2) the manual refresh buttons are gone from the Home page and the Save
#      Manager while the automatic rescans (launch / foreground / data change /
#      pull-to-refresh) stay;
#   3) the 0.1.7 Settings redesign keeps the Save Manager, diagnostics export and
#      About entry points on the Debug / System pages with their accessibility
#      identifiers, and the flat main page has no disclosure chevrons;
#   4) the library cards have no AOT badge any more (the AOT state stays in the
#      log and the diagnostics export) and no visible "..." menu button.
#
# Runs on a plain Linux host: no Xcode, no ROM, no game data. It reads only the
# tracked Swift sources, the two Localizable.strings tables and the app README.
# Exit status: 0 all checks pass, 1 one or more failed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${ROOT}"

checks=0
failures=0
pass() { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n' "$1" >&2; }
check() { # description command...
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "${description}"; else fail "${description}"; fi
}
contains() { grep -Fq -- "$2" "$1"; }
lacks() { ! grep -Fq -- "$2" "$1"; }
occurrences() { grep -Fc -- "$2" "$1" 2>/dev/null || true; }
section() { printf '\n%s\n' "$1"; }

APP=ios/app
LIB="${APP}/Sources/GameLibrary.swift"
HOME="${APP}/Sources/HomeView.swift"
SAVE="${APP}/Sources/SaveManagerView.swift"
SETTINGS="${APP}/Sources/SettingsView.swift"
SETTINGS_PAGES="${APP}/Sources/SettingsPages.swift"
CONTENT="${APP}/Sources/ContentView.swift"
EN="${APP}/Resources/en.lproj/Localizable.strings"
ZH="${APP}/Resources/zh-Hans.lproj/Localizable.strings"
README="${APP}/README.md"

section 'Delete game: library model (GameLibrary.swift)'
check "GameLibrary has a deleteGame(titleID:completion:) entry point" contains "${LIB}" 'func deleteGame(titleID:'
check "the deletion produces a GameDeletionSummary" contains "${LIB}" 'struct GameDeletionSummary'
check "the pushed game data folder is removed" contains "${LIB}" 'try fileManager.removeItem(at: gameDirectory)'
check "the game's battery saves are removed" contains "${LIB}" 'SaveDataStore.batterySaveDirectory(namespace: namespace)'
check "the game's instant save states are removed" contains "${LIB}" 'SaveStateSupport.statesDirectory(namespace: namespace)'
check "the per-game graphics warm-up marker is cleared" contains "${LIB}" 'GraphicsWarmUpMarker.clear(romKey: titleID)'
check "the play history entry is dropped" contains "${LIB}" 'history.lastPlayed.removeValue(forKey: titleID)'
check "the deleted title is hidden from the library" contains "${LIB}" 'removed.removed[titleID] = Date()'
check "the removal record persists to removedGames.json" contains "${LIB}" 'removedGamesURL'
check "the removal record is read on launch" contains "${LIB}" 'removed = readRemovedGames()'
check "reload filters hidden titles out of the catalog" contains "${LIB}" 'dataByTitle[game.titleID] != nil || removed.removed[game.titleID] == nil'
check "pushing a deleted game again restores it" contains "${LIB}" 'was pushed again; showing it in the library again'
check "the hidden-game count is published for the UI" contains "${LIB}" '@Published private(set) var hiddenGameCount'
check "only a direct child of Documents/Games can be deleted" contains "${LIB}" 'isGamesChild'
check "the deleted folder name must be a title id" contains "${LIB}" 'GameCatalog.normalizedTitleID(gameDirectory.lastPathComponent) != nil'
check "save folders outside their root are refused" contains "${LIB}" 'let isChild = standardized.deletingLastPathComponent()'
check "a failed game-data removal aborts instead of hiding the game" contains "${LIB}" 'GameDeletionError.gameDataNotRemoved'
check "deleting drops the in-memory library entry" contains "${LIB}" 'entries.removeAll { $0.titleID == titleID }'
check "the hidden count updates immediately after a delete" contains "${LIB}" 'hiddenGameCount += 1'
check "a pending launch of the deleted title is failed" contains "${LIB}" 'notifyWaiters(titleID: titleID, state: .invalid([.folderMissing(titleID)]))'

section 'Delete game: Home page (HomeView.swift)'
check "long-pressing a card opens its context menu" contains "${HOME}" '.contextMenu {'
check "the context menu carries the Delete Game action" contains "${HOME}" 'Label(L10n.tr("Delete Game"), systemImage: "trash")'
check "the delete action keeps its accessibility id" contains "${HOME}" 'accessibilityIdentifier("game-delete-action")'
check "VoiceOver gets a Delete Game action without a long press" contains "${HOME}" '.accessibilityAction(named: Text(L10n.tr("Delete Game")))'
check "the visible ellipsis menu button is gone" lacks "${HOME}" 'ellipsis.circle.fill'
check "the old visible-menu accessibility id is gone" lacks "${HOME}" 'game-delete-menu'
check "HomeView has no visible Menu container left" lacks "${HOME}" ' Menu {'
check "the delete action is destructive" contains "${HOME}" 'Button(role: .destructive) {'
check "deleting asks a second time" contains "${HOME}" '.alert(deleteConfirmationTitle, isPresented: $isDeleteConfirmationPresented)'
check "the confirmation names the exact game" contains "${HOME}" 'Delete “%@”?'
check "the confirmation says it cannot be undone" contains "${HOME}" 'This cannot be undone.'
check "the confirmation lists data, saves and settings" contains "${HOME}" 'battery saves, instant save states, play history and per-game settings'
check "the home page calls GameLibrary.deleteGame" contains "${HOME}" 'library.deleteGame(titleID: entry.titleID)'
check "a running runtime is released before the files are removed" contains "${HOME}" 'model.unload { self.performDeletion(entry) }'
check "the result banner reports a deletion" contains "${HOME}" 'accessibilityIdentifier("game-deleted")'
check "a failed deletion shows an error banner" contains "${HOME}" 'accessibilityIdentifier("game-delete-error")'
check "the empty state explains hidden deleted games" contains "${HOME}" 'library.hiddenGameCount > 0'

section 'AOT badge removed from the library cards'
check "HomeView no longer renders an AOT badge" lacks "${HOME}" 'L10n.tr("AOT")'
check "HomeView no longer renders a No AOT badge" lacks "${HOME}" 'L10n.tr("No AOT")'
check "the green AOT badge state is gone" lacks "${HOME}" 'return (L10n.tr("AOT"), .green)'
check "a ready game returns no badge" contains "${HOME}" 'private func cardState(_ entry: GameEntry) -> (label: String, tint: Color)?'
check "the remaining attention badge is optional" contains "${HOME}" 'if let state = state {'
check "the attention badges keep their labels" contains "${HOME}" 'L10n.tr("Data missing")'
check "AOT availability stays in the library model" contains "${LIB}" 'func aotAvailability(for entry: GameEntry) -> AOTAvailability'
check "diagnostics still export the AOT fields" contains "${APP}/Sources/DiagnosticsReport.swift" 'aot_diagnostics='
check "About still shows the AOT state" contains "${APP}/Sources/AboutView.swift" 'aboutRow("AOT code", model.aotStatus.title)'

section 'Refresh buttons removed, automatic refresh kept'
check "HomeView has no refresh-button identifier" lacks "${HOME}" 'library-refresh'
check "HomeView has no refresh icon" lacks "${HOME}" 'arrow.clockwise'
check "HomeView has no Refresh library label" lacks "${HOME}" 'Refresh library'
check "HomeView keeps pull-to-refresh" contains "${HOME}" '.refreshable { library.refresh() }'
check "HomeView refreshes only through pull-to-refresh" test "$(occurrences "${HOME}" 'library.refresh()')" -eq 1
check "ContentView still rescans at launch and on foreground" test "$(occurrences "${CONTENT}" 'library.refresh()')" -eq 2
check "SaveManagerView has no refresh-button identifier" lacks "${SAVE}" 'save-manager-refresh'
check "SaveManagerView has no refresh icon" lacks "${SAVE}" 'arrow.clockwise'
check "SaveManagerView keeps its reload path" contains "${SAVE}" 'private func refresh() {'
check "SaveManagerView reloads when it opens" contains "${SAVE}" '.onAppear {'
check "SaveManagerView reloads when the library changes" contains "${SAVE}" '.onChange(of: library.entries.map { $0.titleID })'
check "SaveManagerView reloads after actions" test "$(occurrences "${SAVE}" 'refresh()')" -ge 3
check "SaveManagerView keeps Done but no extra toolbar item" test "$(occurrences "${SAVE}" 'ToolbarItem(placement:')" -eq 1

section 'Localization tables'
check "en table has no Refresh library key" lacks "${EN}" '"Refresh library"'
check "zh table has no Refresh library key" lacks "${ZH}" '"Refresh library"'
check "no Swift source mentions Refresh library" bash -c '! grep -rFq -- "Refresh library" ios/app/Sources'
check "en 0.1.3 block is appended" contains "${EN}" '--- 0.1.3 library deletion'
check "zh 0.1.3 block is appended" contains "${ZH}" '0.1.3 游戏库删除'
check "the stale Refresh-the-library message is retired (en)" lacks "${EN}" 'Refresh the library.'
check "the stale Refresh-the-library message is retired (zh)" lacks "${ZH}" '请刷新游戏库。'
check "the pull-down hint is translated (en)" contains "${EN}" 'Pull down on the library to refresh it.'
check "the pull-down hint is translated (zh)" contains "${ZH}" '在游戏库下拉即可刷新。'

new_keys=(
  "Delete Game"
  "Game actions"
  "Delete this game?"
  "Game deleted"
  "“%@” was deleted from this device."
  "Some of the game's files could not be deleted: %@"
  "That game is not in the library any more."
  "Could not delete the game's data: %@"
  "the folder “%@” is not inside Documents/Games."
  "“%@” is outside its expected folder; not deleted."
  "Deleted games stay hidden until the desktop launcher pushes their game data again."
)
for key in "${new_keys[@]}"; do
  check "en table has \"${key}\"" contains "${EN}" "\"${key}\" ="
  check "zh table has \"${key}\"" contains "${ZH}" "\"${key}\" ="
done
check "en has the delete confirmation message" contains "${EN}" '"The game data of “%@” is removed from this device, together with its battery saves'
check "zh has the delete confirmation message" contains "${ZH}" '"The game data of “%@” is removed from this device, together with its battery saves'
for key in "“%@” was deleted from this device." "Some of the game's files could not be deleted: %@" "Could not delete the game's data: %@"; do
  en_line="$(grep -F -- "\"${key}\" =" "${EN}" | head -n 1 || true)"
  zh_line="$(grep -F -- "\"${key}\" =" "${ZH}" | head -n 1 || true)"
  en_specs="$(grep -o '%' <<<"${en_line}" | wc -l | tr -d '[:space:]')"
  zh_specs="$(grep -o '%' <<<"${zh_line}" | wc -l | tr -d '[:space:]')"
  check "same format placeholders for \"${key}\"" test "${en_specs}" -eq "${zh_specs}"
done

section '0.1.7 Settings keeps the supporting rows (task-42)'
check "Save Manager row identifier" contains "${SETTINGS_PAGES}" '"settings-save-manager"'
check "Export logs row identifier" contains "${SETTINGS_PAGES}" '"settings-export-logs"'
check "About row identifier" contains "${SETTINGS_PAGES}" '"settings-about"'
check "the settings main page has the category menu" contains "${SETTINGS}" 'SettingsCategory.allCases'
check "the settings main page uses the iOS grouped style" bash -c '! grep -Fq -- "preferredColorScheme(.dark)" ios/app/Sources/SettingsView.swift && grep -Fq -- "listStyle(.insetGrouped)" ios/app/Sources/SettingsView.swift'
check "the Debug page keeps the Save Manager link" contains "${SETTINGS_PAGES}" 'SaveManagerView(model: model, saveStates: model.saveStates)'
check "the Debug page keeps the diagnostics export" contains "${SETTINGS_PAGES}" 'DiagnosticsExporter.write(model: model, settings: settings)'
check "the settings main page has no disclosure chevrons" bash -c '! sed -n "/private struct SettingsMainRow/,/^}/p" ios/app/Sources/SettingsView.swift | grep -Fq -- "chevron"'

section '0.1.7-beta2 settings layout (task-45)'
check "Layout page replaced the direct screen-layout jump" contains "${SETTINGS_PAGES}" 'LayoutSettingsPage(settings: settings, model: model)'
check "Layout page has the Performance monitoring group" contains "${SETTINGS_PAGES}" 'Text("Performance monitoring")'
check "Layout page binds the swap screens setting" contains "${SETTINGS_PAGES}" 'swapScreens'
check "Gamepad page has the haptics row" contains "${SETTINGS_PAGES}" 'settings-haptics'
check "Graphics page no longer shows the renderer row" bash -c '! grep -Fq -- "settings-renderer" ios/app/Sources/SettingsPages.swift'
check "System page has the appearance row" contains "${SETTINGS_PAGES}" 'settings-appearance'
check "Other page keeps storage and About" bash -c 'grep -q "OtherSettingsPage" ios/app/Sources/SettingsPages.swift && grep -q "settings-about" ios/app/Sources/SettingsPages.swift'
check "Debug page reports the AOT coverage" contains "${SETTINGS_PAGES}" 'model.aotDiagnostics.aotPercent'
check "Reset All Settings removes the app defaults domain" contains "${SETTINGS}" 'removePersistentDomain(forName: bundleIdentifier)'
check "Reset All Settings asks the user to relaunch" contains "${SETTINGS}" 'Quit and reopen 3ds2apple for the default settings to take effect.'

section 'Docs describe the delete semantics'
check "README documents Deleting a game" contains "${README}" '### Deleting a game'
check "README documents the long-press context menu" contains "${README}" 'Long-press a game'
check "README has no card ... menu left" lacks "${README}" '`...` menu'
check "README says a ready card has no AOT badge" contains "${README}" 'no AOT badge'
check "README says the deletion cannot be undone" contains "${README}" 'cannot be undone'
check "README lists the removed data folders" contains "${README}" 'Documents/data/<save namespace>/'
check "README documents the removedGames.json record" contains "${README}" 'Documents/Library/removedGames.json'
check "README says there is no refresh button" contains "${README}" 'there is no refresh button'

printf '\n%ld checks, %ld failures\n' "${checks}" "${failures}"
if [[ "${failures}" -ne 0 ]]; then
  exit 1
fi