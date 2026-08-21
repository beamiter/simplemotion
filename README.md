# SimpleMotion

Visible-target motion for Vim9. It labels two-character matches across the
current tab, or visible lines above/below the cursor, with popup hints.

The plugin exposes `<Plug>(simplemotion-overwin-f2)`,
`<Plug>(simplemotion-down)` and `<Plug>(simplemotion-up)` and leaves user keys
untouched. It operates on displayed Vim buffers, so local and SimpleRemote
buffers behave identically.

Configure it before the plugin loads:

```vim
let g:simplemotion_keys = 'asdfghjklqwertyuiopzxcvbnm'
let g:simplemotion_smartcase = 1
let g:simplemotion_max_targets = 500
```

`g:simplemotion_max_targets` is a hard non-negative cap shared by searches and
line motions; `0` disables target collection. Invalid option types fall back to
the defaults, and an unusable key alphabet falls back to `asdfghjkl`.
