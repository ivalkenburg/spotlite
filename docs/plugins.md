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
| `id`, `name`, `commands` | Required. Ids use letters, digits, `.`, `-` and `_`. A plugin id cannot start with `.`, and plugin ids must be unique ignoring letter case. |
| `executable` | Path inside the plugin's folder; must have the executable bit. Not needed when every action is `open`, `copy` or `menu`. |
| `timeout` | Seconds a run may take, 1 to 60. Default 10. |
| `settings` | Optional configuration fields, shared by all of the plugin's commands. See below. |

A command is a root search result. It ranks, hides, takes an alias and learns launch
history like an app. `keyword` finds it by a name its title lacks, until the user sets an
alias of their own in Settings → Items.

## Configuration

Select a plugin in Settings → Plugins and click Configure. Spotlite builds the form
from an optional `settings` array in the manifest; no script runs to show or validate it.

```json
"settings": [
  { "id": "organization", "label": "Organization", "type": "text",
    "description": "The organization to search.", "required": true },
  { "id": "limit", "label": "Result limit", "type": "number",
    "default": 20, "min": 1, "max": 50 },
  { "id": "archived", "label": "Include archived", "type": "boolean", "default": false },
  { "id": "token", "label": "Access token", "type": "secret" },
  { "id": "sort", "label": "Sort by", "type": "choice", "default": "stars",
    "options": [{ "value": "stars", "label": "Stars" }, { "value": "updated", "label": "Updated" }] }
]
```

Every field needs a unique `id` (the same plain characters as plugin ids), a nonempty
`label`, and a `type`. `description`, `required`, and `default` are optional. At most 64
fields are supported.

| Type | Value and validation |
| --- | --- |
| `text` | A string. Required text cannot be empty or whitespace-only. Whitespace in a saved value is preserved. |
| `number` | A finite JSON number, including fractions. Optional `min` and `max` are inclusive. |
| `boolean` | A JSON boolean, defaulting to `false`. A required toggle can still be `false`. |
| `choice` | A string matching an option's `value`. Options need unique, nonempty values and nonempty labels. |
| `secret` | A string kept in the Keychain, never in the settings file. Validated like `text`; no `default`. |

A declared default must satisfy the field's type, range, choices, and required rule.
An invalid schema makes the plugin unusable and Settings explains why.

Save commits valid values together; Cancel discards edits. Reset Settings asks before
removing the saved configuration and restoring defaults. Reset takes effect immediately,
even if the configuration sheet is subsequently cancelled. Plugin-owned data is retained.
Saving settings never repeats the command that opened the form.

Commands with missing required values or invalid saved values remain searchable with
“Setup required”. Activating one opens configuration without executing its action.
After a manifest update, Reload revalidates saved values and applies defaults for new
fields. Invalid values remain visible for correction. Optional values without a default
are omitted from the effective configuration when unset; an empty text field is a string.

Each executable invocation receives the effective configuration as one JSON object in
`SPOTLITE_CONFIG`, retaining string, number, and boolean types. Only declared keys are
included. No settings produces `{}`. Values are literal data: Spotlite does not expand
them into manifest `args`, `open` targets, or `copy` text.

For example, a script using `jq` can read `printf '%s' "$SPOTLITE_CONFIG" | jq -r '.organization'`.
The GitHub example demonstrates an organization filter and result limit.

Configuration is stored in `~/Library/Application Support/Spotlite/PluginSettings/<id>.json`,
separate from plugin code and plugin-owned data. It survives disabling, replacement, removal,
and reinstallation. Saving drops obsolete keys. The JSON object is limited to 64 KB.

A `secret` value is stored as a generic password in the login keychain (service
`com.igorv.spotlite.plugin.<id>`, account the field id) and appears in `SPOTLITE_CONFIG` as
a string; it is never written to the settings file, and an optional secret left unset is
omitted. The form never shows a saved secret: it reads “Saved”, typing replaces it, and
Clear removes it on Save. Reset Settings removes the plugin's secrets; removing the plugin
keeps them, like its other settings. Secrets are read with the rest of the configuration,
not per run. A build signed by a different certificate than the one that saved a secret
(a self-built copy, for example) asks for Keychain access the first time it reads it.

Changes apply to the next invocation. An already-running process keeps its original
snapshot. Values are read at first use, on Reload, and after a configuration change;
there is no background watcher, polling, or configuration I/O while typing a root query.

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
| `SPOTLITE_CONFIG` | Effective configuration as a JSON object, with defaults applied; `{}` when no fields are declared |
| `PATH` | Spotlite's, plus `/opt/homebrew/bin`, `/opt/homebrew/sbin` and `/usr/local/bin` |

A non-zero exit is a failure; the first line on standard error is shown. A run that
exceeds the timeout, or a search superseded by newer typing, is terminated. Redirect the
output of anything left running in the background (`cmd >/dev/null 2>&1 &`).

Leaving a list or search cancels its pending retrieval. An explicit `run` action
continues to completion or timeout, including its copy/open/toast response. A late
`keepOpen` response cannot replace rows after leaving its level or starting a newer action.

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
