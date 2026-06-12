# Agent Memory

- Food search suggestions must come from one shared ranked/deduped path across dashboard, home, and conversation composers. Do not add another local matcher unless it feeds that shared path.
- Frequent foods should not be evicted by recency-only sorting. Keep enough food memory loaded and rank frequent staples ahead of one-off recent foods where appropriate.
- Composer controls should bottom-align as the text input grows; plus, search, voice, stop, and send buttons should not float vertically centered beside multiline text.
- Dashboard keyboard lift must be computed from the unshifted composer frame so an existing offset is not applied twice after search sheets, food selections, or keyboard frame changes.
- UI polish changes need simulator or device visual checks when feasible, especially composer, keyboard, drawer gestures, search popups, widgets, and Liquid Glass surfaces.
