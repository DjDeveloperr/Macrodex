# Agent Memory

- Food search suggestions must come from one shared ranked/deduped path across dashboard, home, and conversation composers. Do not add another local matcher unless it feeds that shared path.
- Food suggestions must be meal-context aware. Foods the user usually logs for the current meal should outrank generic recent or wrong-meal items, and the focused fixture should prove meal-specific frequent foods win.
- Frequent foods should not be evicted by recency-only sorting. Keep enough food memory loaded and rank frequent staples ahead of one-off recent foods where appropriate.
- Composer controls should bottom-align as the text input grows; plus, search, voice, stop, and send buttons should not float vertically centered beside multiline text.
- Dashboard keyboard lift must be computed from the unshifted composer frame so an existing offset is not applied twice after search sheets, food selections, or keyboard frame changes.
- UI polish changes need simulator or device visual checks when feasible, especially composer, keyboard, drawer gestures, search popups, widgets, and Liquid Glass surfaces.
- Widgets must be rendered and visually inspected from actual WidgetKit SwiftUI output before claiming polish. Keep rendered screenshots/previews for affected widget families and verify they do not clip, truncate, or depend on invisible widget-only backgrounds.
- iOS AI/Siri integration should expose typed App Intents, AppEntities, and App Shortcuts that return structured data; Siri/Apple Intelligence should compose answers from those entities instead of the app baking Siri prose into UI-only flows.
- Food Spotlight indexing must include favorites, most logged foods, and recent foods; each result should deep link to food details and expose a log-today quick action when the public APIs support it.
- FoundationModels support must use only public SDK symbols. Keep `system` as the no-login default; wire `pcc` through iOS 27's `PrivateCloudComputeLanguageModel` only behind Xcode/iOS 27 SDK gates, with `com.apple.developer.private-cloud-compute` in app entitlements. Verify stable Xcode still builds and Xcode beta compiles the PCC path; runtime PCC may require a physical iOS 27 device while simulator beta bugs remain.
- TestFlight build numbers must use Macrodex's timestamp format `YYYYMMDDHHMM`, not `GITHUB_RUN_NUMBER`; small numeric builds like `68` get buried behind existing timestamp builds. Verify with the CI `Set TestFlight build number` log and ASC/TestFlight showing the timestamp build at the top of the Public Beta group.
