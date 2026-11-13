# Plugins

A plugin adds commands to search. It is a folder with a `plugin.json` and, usually, one
executable in any language. Spotlite starts the executable only when one of the plugin's
commands is used, and reads one JSON object from its standard output. Between uses a
plugin costs its manifest in memory: no process, timer or watcher.

Install a plugin folder in Settings → Plugins, or put (or symlink) it in
`~/Library/Application Support/Spotlite/Plugins/` and press Reload. Working examples are
in [`examples/plugins`](../examples/plugins): Caffeinate, a kubectl context switcher and a
GitHub repository search.

A plugin runs with your user's permissions. Install only ones you trust.

## Manifest

```json
{
  "id": "kubectx",
  "name": "Kube Context",
  "version": "1.0.0",
  "description": "Switch the current kubectl context.",
  "author": "you",
  "executable": "kubectx.sh",
  "timeout": 10,
  "commands": [
    {
      "id": "switch",
      "title": "Switch Kube Context",
      "keyword": "kubectx",
      "subtitle": "kubectl",
      "icon": "shippingbox",
      "action": { "type": "list" }
    }
  ]
}
```

| Key | |
| --- | --- |
| `id`, `name`, `commands` | Required. Ids use letters, digits, `.`, `-` and `_`. |
| `executable` | Path inside the plugin's folder; must have the executable bit. Not needed when every action is `open`, `copy` or `menu`. |
| `timeout` | Seconds a run may take, 1 to 60. Default 10. |

A command is a root search result. It ranks, hides, takes an alias and learns launch
history like an app. `keyword` finds it by a name its title lacks, until the user sets an
alias of their own in Settings → Items.

## Actions

A command and every row carry one action, which is what Return does.

| Action | Effect | Starts the executable |
| --- | --- | --- |
| `{"type":"open","url":"…"}` | Opens a URL or a file path, closes the panel | no |
| `{"type":"copy","text":"…"}` | Copies the text, closes the panel | no |
| `{"type":"menu","items":[…]}` | Enters a fixed list | no |
| `{"type":"list","args":[…]}` | Enters a list printed once; Spotlite filters it as you type | once |
| `{"type":"search","args":[…],"debounce":200,"minQuery":1}` | Enters a list printed for each query | per query, after typing pauses |
| `{"type":"run","args":[…],"keepOpen":false}` | Runs and applies the response; with `keepOpen` the panel stays and the list reloads | once |

Tab also enters `menu`, `list` and `search`. Backspace on an empty query or Shift-Tab goes
back. ⌥↩ on a row whose action is `open` copies its address.

## Running

The executable is called as `executable <args…>`, and for `search` with the query as the
last argument. The working directory is the plugin's folder. Environment:

| Variable | |
| --- | --- |
| `SPOTLITE_QUERY` | What is typed |
| `SPOTLITE_PLUGIN_DIR` | The plugin's folder |
| `SPOTLITE_PLUGIN_DATA` | A folder for the plugin's own state; it exists, and survives reinstalling |
| `SPOTLITE_PLUGIN_ID` | The manifest's id |
| `PATH` | Spotlite's, plus `/opt/homebrew/bin`, `/opt/homebrew/sbin` and `/usr/local/bin` |

A non-zero exit is a failure; the first line on standard error is shown. A run that
exceeds the timeout, or a search superseded by newer typing, is terminated. Redirect the
output of anything left running in the background (`cmd >/dev/null 2>&1 &`).

## Response

One JSON object on standard output. Every key is optional and printing nothing is fine.

```json
{
  "items": [
    { "id": "prod", "title": "prod", "subtitle": "Current", "icon": "checkmark.circle.fill",
      "action": { "type": "run", "args": ["use", "prod"] } }
  ],
  "toast": { "text": "Switched to prod", "symbol": "checkmark.circle", "style": "success" },
  "copy": "text for the clipboard",
  "open": "https://example.com",
  "update": [
    { "command": "switch", "icon": "bolt.fill", "subtitle": "prod", "expires": 1794601717 }
  ]
}
```

- `items`: rows for `list` and `search`, at most 500. `title` is required; a row without an
  `action` only informs. `subtitle` shows at the right of the selected row.
- `toast`: a string, or an object. `"style":"failure"` shows even when confirmation
  messages are off.
- `update`: changes how one of the plugin's commands looks in root results, until
  `expires` (seconds since 1970) or the next update. Naming only the `command` restores the
  manifest's look. Updates live in memory, so report the state again from a `list`.

`icon` is an SF Symbol name, an image file (`icon.png`, relative to the plugin's folder
unless absolute), or any other path, whose Finder icon is shown (`/Applications/Safari.app`).
