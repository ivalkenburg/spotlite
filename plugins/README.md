# Plugins

A plugin adds commands to search. It is a folder with a `plugin.json` and, usually, one
executable in any language. Spotlite starts the executable only when one of the plugin's
commands is used, and reads one JSON object from its standard output, or one row per
line when the action [streams](#streaming). Between uses a
plugin costs its manifest in memory: no process, timer or watcher.

Install a plugin in Settings → Plugins from a folder or an address (see
[Installing](#installing)), or put (or symlink) it in
`~/Library/Application Support/Spotlite/Plugins/` and choose ⋯ → Reload Plugins. Working examples are
in [`plugins`](.): Caffeinate, a kubectl context switcher, a
GitHub repository search and Find Files, which streams.

A plugin runs with your user's permissions. Install only ones you trust.

## Manifest

```json
{
  "$schema": "https://raw.githubusercontent.com/ivalkenburg/spotlite/main/plugins/plugin.schema.json",
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
| `id`, `name`, `commands` | Required. Ids use letters, digits, `.`, `-` and `_`, up to 128 characters. A plugin id cannot start with `.`, and plugin ids must be unique ignoring letter case. Command ids are unique within the plugin. |
| `version`, `description`, `author` | Optional text shown in Settings and when installing. Check for Updates compares `version`. |
| `executable` | Path inside the plugin's folder; must have the executable bit. Not needed when every action is `open`, `copy` or `menu`. |
| `timeout` | Seconds a run may take, 1 to 60. Default 10. |
| `settings` | Optional configuration fields, shared by all of the plugin's commands. See below. |
| `$schema` | Optional, ignored by Spotlite. See below. |

`plugin.json` must fit within 256 KB, including when installed from a folder.

A command is a root search result. It ranks, hides, takes an alias and learns launch
history like an app. `keyword` finds it by a name its title lacks, until the user sets an
alias of their own in Settings → Items.

[`plugin.schema.json`](plugin.schema.json) describes the manifest as a JSON Schema. Set
`"$schema"` to its address, as above and in the examples, and an editor such as VS Code
completes keys, shows what each one does and marks mistakes. The schema is stricter than
Spotlite: it also marks keys Spotlite ignores, such as a misspelled one, and values
Spotlite would clamp, such as a `timeout` of 90.
[`plugin-response.schema.json`](plugin-response.schema.json) describes what the executable
prints (see [Response](#response)).

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
  { "id": "repos", "label": "Repositories", "type": "list", "default": ["octo/app"] },
  { "id": "checkout", "label": "Checkout", "type": "folder", "default": "~/Code", "mustExist": true },
  { "id": "sort", "label": "Sort by", "type": "choice", "default": "stars",
    "options": [{ "value": "stars", "label": "Stars" }, { "value": "updated", "label": "Updated" }] }
]
```

Every field needs a unique `id` (the same plain characters as plugin ids), a nonempty
`label`, and a `type`. `description`, `required`, and `default` are optional. At most 64
fields are supported. `min`, `max`, `options`, `multiline`, `mustExist` and `extensions`
belong to the types below that name them; on another type they make the manifest invalid.

| Type | Value and validation |
| --- | --- |
| `text` | A string. Required text cannot be empty or whitespace-only. Whitespace in a saved value is preserved. |
| `number` | A finite JSON number, including fractions. Optional `min` and `max` are inclusive. |
| `boolean` | A JSON boolean, defaulting to `false`. A required toggle can still be `false`. |
| `choice` | A string matching an option's `value`. Options need unique, nonempty values and nonempty labels. |
| `secret` | A string kept in the Keychain, never in the settings file. Validated like `text`; no `default`. |
| `file`, `folder` | A path string, typed or picked with Choose…. Optional `mustExist: true` requires an existing file or folder. `file` takes optional `extensions` (such as `["json"]`) for the open panel. |
| `list` | A JSON array of strings, edited one item per line; lines are trimmed and blank ones dropped. Required means at least one item. A `default` is an array. |

`"multiline": true` gives a `text` field a multi-line editor; its value is still one string.

A leading `~` in a `file` or `folder` value is kept in the saved value and expanded to the
home folder in `SPOTLITE_CONFIG`. `mustExist` is checked when saving and when settings are
read (first use and Reload), not continuously: a path removed later makes the plugin show
“Setup required” after the next Reload or launch. A default path that does not exist is not an error.

A declared default must satisfy the field's type, range, choices, and required rule.
An invalid `settings` array makes the plugin unusable and Settings explains why.

Save commits valid values together; Cancel discards edits. Reset Settings asks before
removing the saved configuration and restoring defaults. Reset takes effect immediately,
even if the configuration sheet is subsequently cancelled. Plugin-owned data is retained.
Saving settings never repeats the command that opened the form.

Commands with missing required values or invalid saved values remain searchable with
“Setup required”. Activating one opens configuration without executing its action.
After a manifest update, Reload revalidates saved values and applies defaults for new
fields. Invalid values remain visible for correction. Optional values without a default
are omitted from the effective configuration when unset; an empty text field is a string
and an empty list is `[]`.

Each executable invocation receives the effective configuration as one JSON object in
`SPOTLITE_CONFIG`, retaining string, number, boolean, and array types. Only declared keys are
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
| `{"type":"run","args":[…],"keepOpen":false}` | Closes the panel at once and runs in the background, then applies the response; with `keepOpen` the panel stays and the list reloads | once |

A `search` runs once typing has paused for `debounce` milliseconds (0 to 2000, default
200), and only when the query has at least `minQuery` characters (default 1).

Tab also enters `menu`, `list` and `search`. Backspace on an empty query or Shift-Tab goes
back. ⌥↩ on a row whose action is `open` copies its address, unless the row binds ⌥ itself
(see [Other actions](#other-actions)).

`list`, `search` and `menu` also take:

| Key | |
| --- | --- |
| `emptyText` | Shown when the level has no rows: nothing came back, or typing filtered every row out. A `search` also shows it while the query is shorter than `minQuery`. Default: “No results”, and nothing below `minQuery`. Nothing shows while the first answer is still loading. |
| `sort` | `list` and `menu` only. `false` keeps matches in the plugin's order; typing still narrows the rows. Default `true`, best match first. |
| `stream` | `list` and `search` only. `true` reads one row per line and shows rows as they arrive. See [Streaming](#streaming). Default `false`. |

### Other actions

A command or a row can offer more than Return's action. `actions` lists them, each with a
`title`, any `action` above, an optional SF Symbol `icon` and an optional `shortcut`:

```json
{ "title": "octo/app", "action": { "type": "open", "url": "https://github.com/octo/app" },
  "actions": [
    { "title": "Copy Clone URL", "shortcut": "cmd", "icon": "doc.on.doc",
      "action": { "type": "copy", "text": "https://github.com/octo/app.git" } },
    { "title": "Open Issues",
      "action": { "type": "open", "url": "https://github.com/octo/app/issues" } }
  ] }
```

`shortcut` is a modifier held with Return: `cmd`, `opt`, `shift` or `ctrl` (also `command`,
`option`, `alt` and `control`), or several joined by `+`, such as `cmd+shift`. While it is
held, the selected row shows the action's title. Only the exact chord matches. The first
action to claim a chord gets it; a later one is still listed without it. An action without
a `shortcut` is reached only from the action list. A declared `opt` replaces the built-in
⌥↩ copy.

⌘K opens the selected row's action list: Return's action first, then the others in order,
each with its key, then the built-in Copy Link on an `open` row. Typing filters it, Return
or a click runs one, and Escape, Backspace on an empty query, Shift-Tab or ⌘K again goes back
to the rows with the query and selection as they were. An action that enters a level goes
back to the row, not to the list.

At most 16 actions are read. An action that is malformed (no title, an unknown action type
or `shortcut`) is skipped alone; `actions` inside an action are ignored. On rows without an
`action`, the list still offers the others.

### Confirmation

Any action can ask before it runs with `confirm` beside its `type`, a question or an object:

```json
{ "type": "run", "args": ["delete", "main"], "keepOpen": true,
  "confirm": { "title": "Delete branch main?", "message": "It is not merged.",
               "button": "Delete", "destructive": true } }
```

`"confirm": "Delete branch main?"` is the short form. The question takes the place of the
rows inside the panel: the chip asks it, the first row is the button (default “Confirm”)
with the `message` beside it, and the second is Cancel. Return or a click on the button runs
the action; Escape, Cancel, Backspace or Shift-Tab goes back to the rows. A Return still held
from the row that asked does not answer it. `destructive` marks the button with a warning
icon. A `confirm` that is not a nonempty string or an object with a `title` drops the row
or action that carries it, rather than running it unasked; on a manifest command it makes
the manifest invalid.

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
| `SPOTLITE_CONFIG_<ID>` | Each set string, number or boolean setting on its own, as described below |
| `SPOTLITE_COMMAND` | Id of the manifest command the user started from, also for rows nested inside its list, search or menu |
| `SPOTLITE_ACTION` | `run`, `list` or `search`: the kind of action that started this run |
| `SPOTLITE_APPEARANCE` | `light` or `dark`, Spotlite's appearance when the run started |
| `SPOTLITE_VERSION` | Spotlite's version, such as `1.1.3`; `0.0.0` when it runs outside its app bundle |
| `PATH` | Spotlite's, plus `/opt/homebrew/bin`, `/opt/homebrew/sbin` and `/usr/local/bin` |

`SPOTLITE_CONFIG_<ID>` takes the setting's id in upper case, with every character other
than `A`–`Z` and `0`–`9` replaced by `_`: `resultLimit` is `SPOTLITE_CONFIG_RESULTLIMIT`.
Strings are passed as they are, `file` and `folder` paths expanded as in `SPOTLITE_CONFIG`, numbers as written in the form (`20`, `0.5`), booleans
as `true` or `false`. A value that is unset is not exported, and other kinds of value
only appear in `SPOTLITE_CONFIG`. When two ids map to the same name (`api-key` and
`api_key`), neither is exported, so a name never depends on the order of the fields;
read them from `SPOTLITE_CONFIG`, which is authoritative and always has every value.

A non-zero exit is a failure; the toast shows the last nonempty line on standard error,
where a traceback or a script under `set -e` leaves the error that stopped it. A run that
exceeds the timeout, prints more than 4 MB, or is a search superseded by newer typing, is
terminated. Redirect the output of anything left running in the background
(`cmd >/dev/null 2>&1 &`).

Output that is not a JSON object fails with “returned invalid JSON”. Settings shows why,
with the start of the output (see [Debugging](#debugging)).

Leaving a list or search cancels its pending retrieval. An explicit `run` action
continues to completion or timeout, including its copy/open/toast response, even after
the panel has closed or opened again; a failure shows a failure toast. Without `keepOpen`
its `items` are ignored, so a late answer never changes the rows of a later search. A late
`keepOpen` response cannot replace rows after leaving its level or starting a newer action.

## Response

One JSON object on standard output, described by
[`plugin-response.schema.json`](plugin-response.schema.json). Every key is optional and
printing nothing is fine.

```json
{
  "items": [
    { "id": "prod", "title": "prod", "subtitle": "Current", "accessory": "eu-west-1",
      "keywords": ["production"], "icon": "checkmark.circle.fill",
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

- `items`: rows for `list` and `search`, at most 500. A `keepOpen` run's `items` replace
  the rows of the list it ran from, except in a `search`. `title` is required; a row without an
  `action` only informs. `subtitle` shows at the right of the selected row. `accessory` is
  short text at the right of every row, such as `"★ 1.2k"` or a date; on the selected row
  the subtitle comes before it. It truncates before the title does. `keywords`, up to 8
  strings, also find the row when typing filters it; a title match ranks above a
  keyword-only one. The same keys work on `menu` items. A row whose keys have the wrong
  type is skipped. Titles and keywords longer than 4,096 characters or 16 KB remain
  available as row data but are excluded from local matching to bound its memory use.
- `actions` work on rows as on commands, and so does `confirm` in a row's `action`; see
  [Other actions](#other-actions) and [Confirmation](#confirmation).
- `toast`: a string, or an object. `"style":"failure"` shows even when confirmation
  messages are off.
- `update`: changes how one of the plugin's commands looks in root results, until
  `expires` (seconds since 1970) or the next update. Naming only the `command` restores the
  manifest's look. Updates live in memory, so report the state again from a `list`.

`icon` is an SF Symbol name, an image file (`icon.png`, relative to the plugin's folder
unless absolute), or any other path, whose Finder icon is shown (`/Applications/Safari.app`).
An image is scaled to fit the row's icon without stretching.

### Streaming

With `"stream": true` on a `list` or `search` action, the executable prints one JSON
object per line ([NDJSON](https://github.com/ndjson/ndjson-spec)) instead of one object,
and each row shows as soon as its line arrives. A slow source (a network page, `find`,
`git log`) shows its first rows while the rest are still coming. A line is described by
`streamLine` in [`plugin-response.schema.json`](plugin-response.schema.json).

```sh
find "$HOME/Documents" -iname "*$1*" |
jq -n -R -c --unbuffered 'limit(200; inputs) | {title: (split("/") | last), action: {type: "open", url: .}}'
```

- A line with a `title` is a row, with the keys of an item in `items`.
- Any other object is a response line: its `items` are more rows, and its `toast`,
  `copy`, `open` and `update` apply when the program exits successfully. When several
  lines give one, the last `toast`, `copy` and `open` win and every `update` applies.
  A whole classic response on one line therefore works too.
- Blank lines are ignored; a line may end in `\r\n`, and the last needs no newline.
- A line that is not a JSON object, or a row whose keys have the wrong type, is skipped
  on its own. The others still show; Settings lists the skipped lines with why.
- Flush every line. Tools buffer output to a pipe, so use `jq --unbuffered`,
  `grep --line-buffered`, `sed -l`, or `fflush()` in awk, and in Python `print(…, flush=True)`.

Typing filters and ranks a `list`'s rows as they arrive, and a row the user selected stays
selected while rows are added. Updates are coalesced, at most one per frame. “Loading…”
shows if no row has arrived after a moment, and while the program runs, also when typing
filters out every row so far. The empty text shows only once the program has exited and
no row matches.

A search superseded by newer typing, or a level the user leaves, stops the program, and
none of its rows show after that. The timeout covers the whole run. After 500 rows the
output is still read, for response lines, but further rows are ignored: stop at 500, as
`limit(500; …)` or `head -n 500` do. The 4 MB output limit covers the whole run.

A run that fails after rows arrived (a non-zero exit, the timeout, too much output) keeps
those rows and shows the failure as a toast; its response lines are not applied. A failure
before any row replaces the list with the error, as without streaming.

## Debugging

In Settings → Plugins, the ⋯ button and a right click on a plugin hold its less frequent
actions. With "Keep each plugin's last run for diagnostics" on (it is off by default),
select a plugin to see its last run since the option was turned on: the
command, action and arguments, the exit status or error, how long it took, the last
16 KB of standard error, the start of standard output and, for a streamed run, how many
rows came and which lines were skipped. It is kept in memory only, and turning the option
off drops it. While it is off, a streamed run also keeps none of its raw output: its
rows are decoded as lines arrive, and the 4 MB limit still counts every byte.

Run Command…, which works with the option on or off, starts one of the plugin's `run`, `list` or `search` commands the same way search
does, with the same environment and configuration. The query field is `SPOTLITE_QUERY`
and, for `search`, the last argument. The sheet shows standard output (indented when it
is JSON) with what Spotlite understood from it, standard error, the exit status and the
time taken. For a streamed command it also says how many rows were decoded and which
lines were skipped, and why. Nothing in the response is applied: no toast, copy, open or update. Stop
ends the run; closing the sheet does too.

Reveal in Finder opens the plugin's folder, and Open Data Folder its
`SPOTLITE_PLUGIN_DATA` folder.

## Installing

The + button in Settings → Plugins installs: Install from Folder… copies a plugin folder,
Browse Gallery… lists plugins to install by name (see [Gallery](#gallery)), and Install
from URL… takes an address:

| Address | |
| --- | --- |
| `https://github.com/owner/repo` | The repository's default branch; `plugin.json` at its top |
| `https://github.com/owner/repo/tree/<ref>/<folder>` | A branch, tag or commit, and the plugin's folder in it. A ref containing `/` (`feat/x`) is found by trying each split. A `…/blob/<ref>/<folder>/plugin.json` link works too. |
| `https://example.com/plugin.zip` | A zip archive with `plugin.json` at its top or in its single top folder |
| `https://example.com/plugin.git#<ref>` | Cloned with `git clone --depth 1`; the optional ref is a branch or tag |

Only `https` is accepted, redirects included. GitHub addresses download GitHub's zip of
the ref, so they need no git. A `.git` address needs git from Xcode, the Command Line
Tools or Homebrew; Spotlite never runs `/usr/bin/git`, which would offer to install the
tools. Only public repositories work: no credentials are sent or asked for.

The download goes to a temporary folder, is checked, and is shown before anything is
installed. A download over 50 MB, an archive that expands past 200 MB or holds more than
10,000 items, an entry with an absolute path or `..`, a link that resolves outside the
plugin's folder, an encrypted or ZIP64 archive, and a folder without a valid
`plugin.json` are all refused, and the temporary folder is removed. Executable bits are
kept.

The confirmation lists the name, id, version, author, description, source, each command
with its action type, the executable and the declared settings. When the id is already
installed it offers Update (with the old and new version) or Reinstall. Replacing is
atomic: if anything fails, the installed copy stays. Settings, secrets and
`SPOTLITE_PLUGIN_DATA` are kept. A plugin whose folder is a symbolic link (a checkout
under development) is never replaced; update the checkout instead.

A plugin installed from an address keeps a source record in
`~/Library/Application Support/Spotlite/PluginSources/<id>.json`: the address, the ref,
the commit when GitHub reports it, and the installed version and date. Settings shows it
below the buttons. A plugin installed from a folder, or linked, has none, and installing
it from a folder later removes the record, as does removing the plugin.

⋯ → Check for Updates asks each recorded source for its version, only when clicked: Spotlite
never checks on its own. A GitHub source is checked by asking GitHub's API for the ref's
current commit and fetching that commit's `plugin.json` alone, so a push is seen at once (if
the API is unreachable or rate limited, the branch's file is used, which may lag a push by a
few minutes); a zip or git source is downloaded
again and discarded. Versions compare as semantic versions (`1.10` is newer than `1.9`,
`1.0.0-beta` precedes `1.0.0`, a leading `v` and `+build` are ignored); a version that is
not one is offered as an update whenever it differs. Update… goes through the same
confirmation.

### Gallery

+ → Browse Gallery… reads the gallery index,
[`index.json`](index.json) on the repository's `main` branch, served
from `raw.githubusercontent.com`. It is fetched only when the sheet opens or Refresh is
clicked: never at launch, in the background or on a timer. While Settings stays open the
last index is kept in memory, and nothing is written to disk.

The sheet lists each plugin's name, version, author, description and tags, with a search
field, and its status: Install… when it is not installed, Update… when the gallery lists a
newer version (compared as in Check for Updates), Installed otherwise. Install… and
Update… hand the entry's `source` to the install sheet, so the download is checked and the
same confirmation, with the manifest and the trust warning, comes before anything is
installed. A plugin installed from the gallery has a source record like any other.

The gallery lists plugins; it does not review them. A listed plugin is third-party code
that runs with your permissions, like one installed from any address.

To propose a plugin, open a pull request that adds an entry to `plugins/index.json`:

```json
{
  "version": 1,
  "plugins": [
    {
      "id": "timezones",
      "name": "Time Zones",
      "description": "Show the time in other cities.",
      "author": "you",
      "version": "1.0.0",
      "source": "https://github.com/you/spotlite-timezones",
      "homepage": "https://github.com/you/spotlite-timezones",
      "icon": "globe",
      "tags": ["time", "travel"]
    }
  ]
}
```

| Key | |
| --- | --- |
| `version` | The index format, `1`. An index with another version is refused with an error. |
| `id`, `name`, `version` | As in the plugin's `plugin.json`. The id is unique in the index, ignoring letter case. |
| `description`, `author` | Required. Up to 500 and 100 characters. |
| `source` | Any address Install from URL… accepts (see the table above). |
| `homepage` | Optional https page, opened by the arrow next to the name. |
| `icon` | Optional SF Symbol name. Images are never downloaded. |
| `tags` | Optional lowercase words for search; the first 8 are used. |

[`plugin-index.schema.json`](plugin-index.schema.json) is the JSON Schema for the
file. Spotlite reads at most 1 MB and 500 entries, and skips an entry that is invalid (a
missing field, an address that is not https, a repeated id) while showing the rest, with
a count of what it skipped.

