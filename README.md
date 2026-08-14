# SimpleMotion

Visible-target motion for Vim9. It labels two-character matches across the
current tab, or visible lines above/below the cursor, with popup hints.

The plugin exposes `<Plug>(simplemotion-overwin-f2)`,
`<Plug>(simplemotion-down)` and `<Plug>(simplemotion-up)` and leaves user keys
untouched. It operates on displayed Vim buffers, so local and SimpleRemote
buffers behave identically.
