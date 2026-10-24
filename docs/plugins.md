# Spotlite plugins · API 1

Plugins are Lua source packages. Spotlite bundles Lua 5.5.1; users do not install an interpreter, compiler or package manager. Each active plugin runs in its own helper process. The launcher matches command metadata locally and starts helpers only when needed.

Caffeinate and GitHub are working reference packages in `Resources/Plugins`. Caffeinate implements the complete keep-awake feature in Lua: power ownership, external activity detection, status menu, dynamic icons, durations and toasts. Swift provides general native resource primitives; GitHub demonstrates nested search, HTTP, credentials, details and multiple actions.

## Install and manage

Open **Settings → Plugins → Add Plugin…** and select a `.spotliteplugin` folder, `manifest.json`, or ZIP. ZIPs can contain the package files directly or one enclosing folder. Spotlite copies packages into its managed directory. ZIP64, encrypted entries, symbolic links, escaping paths, packages larger than 64 MiB uncompressed, and packages with more than 10,000 entries are rejected.

Select a plugin to enable or disable it, show or hide its commands, configure it, control global search participation, Stop, Restart, Force Stop, or open its log. Hiding commands leaves background work and status items active; disabling stops them. The More menu provides updates, rollback, package location and uninstall. Uninstall can retain data and credentials. Bundled plugins stay uninstalled until explicitly imported again.

**Load Development Folder…** references your source directly. Restart reloads Lua source and validates the current manifest. Uninstall preserves that source folder.

Plugins run as trusted local code, with access to standard Lua I/O and OS facilities and the host APIs below. There is no Spotlite sandbox or capability permission system. Native Lua modules and precompiled bytecode are outside the v1 package compatibility contract; distribute Lua source and include all Lua dependencies and resources in your package.

## A first plugin

Create a folder named `Hello.spotliteplugin` with two files:

`manifest.json`:

```json
{
  "id": "com.example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "apiVersion": 1,
  "commands": [{"id": "hello", "title": "Say Hello", "prefix": "hello"}]
}
```

`main.lua`:

```lua
local s = require("spotlite")
return {
    search = function(args)
        return {
            id = "hello", title = "Say Hello",
            items = {{
                id = "greeting", title = "Hello " .. args.query,
                subtitle = "Return copies this greeting", icon = "hand.wave",
                data = {text = "Hello " .. args.query},
                actions = {{id = "copy", title = "Copy Greeting", close = true}}
            }}
        }
    end,
    action = function(args)
        s.clipboard.write({text = args.item.data.text})
    end
}
```

Import the folder, search for “Say Hello”, press Return or Tab, and type a name. Alternatively type `hello ` followed by the name directly in root search. Press Tab on a result for its actions. Escape or Shift-Tab returns to the parent context; an empty Backspace also goes back. Query and selection restoration follows Spotlite's Back Navigation preference.

## Manifest

Required fields are `id`, `name`, semantic `version`, integer `apiVersion: 1`, and a nonempty `commands` array. Plugin and command IDs use letters, digits, `.`, `_` and `-`; use a reverse-domain plugin ID that you own. IDs persist through updates.

Optional fields:

| Field | Meaning |
| --- | --- |
| `entry` | Relative Lua entry file; defaults to `main.lua`. It returns a table of handlers. |
| `description`, `author` | Management metadata. |
| `icon` | SF Symbol name or relative PNG/JPEG/ICNS/PDF/TIFF resource path. |
| `activation` | `demand` (default) or `startup`. Startup invokes the plugin when Spotlite launches. |
| `background` | Set `true` for background coroutines or resources that outlive an open view. |
| `settings` | Array of native configuration fields, described below. |
| `updateURL` | HTTPS URL for update metadata. Checks occur only when the user requests them. |
| `legacyUtilityID` | Optional former built-in utility identifier; migrates its hidden-command preference on first installation. |
| `testEntry` | Optional relative Lua test module, returning a function `(plugin, args)`. Invoked by development checks. |

Each command has `id`, `title`, and optional `subtitle`, `icon`, `keywords`, `prefix`, `global`, `searchMode`, and `debounceMilliseconds`.

`searchMode` is `automatic` (default) or `enter`. Automatic scoped searches debounce for 150 ms by default; a command may choose 0–2000 ms. Enter mode waits for Return after editing. `prefix` is a single word followed by a space. `global: true` makes an automatic command eligible for root queries, but the user must separately enable global search for that plugin. Global search uses a fixed 150 ms debounce and excludes commands in `enter` mode. Global results follow built-in matches and precede web search. Plugin search results preserve the order supplied by the plugin. Static command matching never executes Lua.

## Handlers and asynchronous calls

`main.lua` returns a table with these optional handlers:

- `start(info)`: initialization, with plugin `id`, `entry`, `version` and `apiVersion`. It completes before search/action handlers run.
- `search(args)`: returns a native view. Receives `command`, `title`, `query`, `global`, and the current `view` when inside a scope. A missing handler produces an empty list.
- `event(args)`: optional native event handler. Status menus deliver `status.open` or `status.action`, plus `status` (item ID) and `action` (menu item ID).
- `action(args)`: receives `command`, `query`, the selected `action`, optional `item`, current `view`, and submitted form `values`. Use `s.ui` for navigation or live updates. The result is ignored. An action with `close: true` dismisses the panel after successful completion.

Host calls suspend the current coroutine and resume it on completion. They do not block the launcher or other plugin coroutines. A host error raises a Lua error; use `pcall` when you want to recover. Top-level module loading must complete synchronously; put asynchronous initialization in `start`.

Searches are cancelled when superseded or when their view closes. Cancelled suspended coroutines are closed; cancellable host operations are stopped and obsolete results are ignored. CPU loops and blocking native Lua calls require Stop/Force Stop. Errors include Lua tracebacks. Crashes are reported and require an explicit Restart; there is no restart loop or blanket timeout for background work.

```lua
s.background(function()
    while true do
        -- Synchronize data or perform other author-controlled work.
        s.timers.sleep({seconds = 60})
    end
end)
```

Background work requires `background: true`. `s.background(fn)` returns an ID; `s.cancel_background(id)` cancels another suspended background coroutine and its host operations. Return from a background function to end it normally. Leaving the view cancels foreground work and allows declared background work/resources to continue. Helpers are released when they have no open view, outstanding requests, background coroutines or managed persistent resources. Ordinary Lua module state is therefore temporary. Store durable state through storage APIs. Stop, disable, uninstall and app quit cancel managed work and release resources. Programs deliberately detached through unrestricted OS APIs are outside managed cleanup.

## Views and actions

All views require stable `id` and `title`. Every result requires a stable `id` and `title`; stable IDs let selection follow asynchronous updates. `type` defaults to `list`.

| Type | Content |
| --- | --- |
| `list` | `items`: result array. Each result may have `subtitle`, `icon`, boolean `state`, arbitrary JSON `data`, and `actions`. |
| `detail` | `markdown`: text with inline Markdown formatting, preserved line breaks and selectable links. |
| `form` | `fields`, initial `values`, and submit `actions`. |

Views may also provide `placeholder`, `searchMode`, `data`, and `actions`. Each action has an `id`, `title`, optional `icon`, `close`, arbitrary JSON `data`, and optional keyboard `key` such as `cmd+c` or `cmd+shift+o`. The first result action runs on Return; Tab opens all result actions. Action shortcuts apply to selected list results when no query text is selected. Detail/form actions are native buttons; Return in the search bar invokes the first action.

Field properties: `id`, `title`, `type` (`text`, `secret`, `toggle`, `select`, `number`), optional `placeholder`, `description`, `required`, `defaultValue`, and `options` for selects. Required text and numeric input is validated before submission. Secret configuration fields use Keychain; they are excluded from the JSON settings file. In-panel forms are transient; explicitly use credentials APIs for secrets you want to persist.

Use arrays with sequential integer keys and objects with string keys. Empty tables encode as arrays; use `s.json.object()` when an empty object is required. `s.json.null` represents explicit JSON null. `s.json.encode`/`decode` support nested JSON and Unicode escapes.

## Host API

Every method accepts one table of named arguments, or no arguments when none are needed.

| Method | Arguments and result |
| --- | --- |
| `s.http.request` | `{url, method="GET", headers={}, body?, timeout=30}` → `{status, headers, body, base64}`. HTTP(S), text body plus base64 response data; response downloads are capped at 3 MiB and the serialized result must fit the message limit. HTTP error statuses are returned to the plugin. |
| `s.process.run` | `{executable, arguments={}, directory?, environment?}` → `{status, stdout, stderr}`. Arguments are passed directly, without shell interpolation. Use `/bin/sh` explicitly when needed. Captures both streams up to 3 MiB combined. Cancellation kills the managed process group. |
| `s.clipboard.read` | No arguments → clipboard text or null. |
| `s.clipboard.write` | `{text}` → success boolean. |
| `s.system.open` | `{target}` → success boolean. Opens a URL, application, file or folder; absolute paths and `~` are accepted. |
| `s.system.notify` | `{title?, body?}` → success. Uses macOS notification authorization for Spotlite. |
| `s.system.info` | No arguments → `{pid, osVersion}` for the host application. |
| `s.power.create` | `{id?, type, name?}` → a power assertion handle. An optional stable `id` makes creation idempotent within a plugin. Assertion types are macOS IOPM type strings. |
| `s.power.get` | `{handle}` → whether the plugin owns this assertion. |
| `s.power.release` | `{handle}` → whether an assertion was released. |
| `s.power.list` | No arguments → system assertions `{pid, process, type, name, level}`. Plugins implement filtering and policy themselves. |
| `s.status.set` | `{id, icon, tooltip, menu}` → create/update a menu bar status item. Menu entries have `title`, optional action `id`, `enabled`, or `separator: true`. |
| `s.status.get` | `{id}` → the plugin's current status item description, or null. |
| `s.status.remove` | `{id}` → remove the plugin's status item. |
| `s.toast.show` | `{text, icon?}` → passive feedback using Spotlite's configured message position. |
| `s.commands.update` | `{id, title?, subtitle?, icon?}` → update this plugin's command metadata for the current runtime session. |
| `s.storage.get` | `{key}` → JSON value or null. |
| `s.storage.set` | `{key, value}` → success. Writes atomically. |
| `s.storage.remove` | `{key}` → success. |
| `s.storage.paths` | No arguments → `{data, cache, package}` filesystem paths. |
| `s.credentials.get` | `{key}` → Keychain string or null. |
| `s.credentials.set` | `{key, value}` → success. |
| `s.credentials.remove` | `{key}` → success. |
| `s.settings.get` | No arguments → configuration including defaults and secret fields. |
| `s.settings.set` | Complete configuration object → success. Secret fields are routed to Keychain. |
| `s.ui.push` | A view → push a child view in the panel. |
| `s.ui.replace` | A view → replace the current view without adding a parent. |
| `s.ui.update` | A view with the current view ID → update content while preserving selection. |
| `s.ui.pop` | No arguments → return to the parent. |
| `s.ui.close` | No arguments → dismiss the panel. |
| `s.timers.sleep` | `{seconds, tolerance?}` → resume after a cancellable one-shot delay, with optional coalescing tolerance in seconds. No polling is used. |
| `s.log` | `s.log(message, level?)` → append a diagnostic entry. |

Power assertions and status items are owned resources: stop, disable, uninstall and app quit release them. Plugins implement feature policy through these general APIs. Caffeinate declares startup/background work and requests its own coalescible five-second refresh; there is no feature-specific Swift timer or fallback.

UI calls apply to the active plugin view or a user-invoked action. Background/global search callbacks cannot take over another view. Each protocol message is limited to 4 MiB; split large results and keep view payloads small. Log messages are bounded and logs rotate at 256 KiB.

Data and configuration live in `~/Library/Application Support/Spotlite/Plugins/Data/<id>`. Installed packages and the previous version live beside that directory under `Packages` and `Previous`. Regenerable plugin caches and logs live under `~/Library/Caches/Spotlite`, separate from durable data. Settings secrets are namespaced by plugin ID in Keychain; namespacing is organization, not a security boundary.

## Updates and compatibility

`updateURL` returns:

```json
{
  "version": "1.1.0",
  "apiVersion": 1,
  "downloadURL": "https://example.com/Hello-1.1.0.zip",
  "sha256": "<64 hexadecimal characters>"
}
```

Spotlite checks compatibility before offering an update. After user approval, it downloads the ZIP, checks SHA-256, validates the package ID/version/API, and preserves the previous package for rollback. Failed or incompatible imports leave installed code intact. Updates do not replace configuration or durable storage. Changing an ID installs a different plugin rather than migrating data.

API 1 remains compatible within its major version. Plugins declare the API major they require, independently of the Spotlite app version. Unsupported majors are rejected with an explanation. Lua source avoids bytecode/ABI coupling to a specific runtime build.

## Development checks

Run `make test` for package installation, update preservation, rollback, configuration retention, ZIP handling and core search tests. `make` builds and signs both the app and helper.

For native integration checks, use an isolated plugin registry:

```sh
SPOTLITE_DEV_PLUGIN_ROOT="$(mktemp -d)" \
SPOTLITE_DEV_PLUGINS=1 SPOTLITE_DEV_PIN=1 \
SPOTLITE_DEV_CAPTURE_DIR="$PWD/build/plugin-checks" \
  build/Spotlite.app/Contents/MacOS/Spotlite
```

The hook exercises the actual runner, cancellation, native forms/details, Caffeinate, storage/process APIs, background lifetime, crash recovery and Force Stop. It restores Caffeinate to off and uses a temporary fixture. Add `SPOTLITE_DEV_GITHUB=1` for a live public GitHub search; private search requires your configured token and is not covered by the hermetic checks.

`--bench` includes enabled command metadata in the synchronous result-assembly measurement. Compare on the same machine and index. Plugin startup, helper memory and author-controlled background work are separate measurements.

`make test-plugins IDENTITY=-` builds an ad-hoc signed app and runs the native checks with a temporary registry. Bundled plugins can provide `testEntry` modules; the generic harness runs those without embedding their feature behavior in Swift.

Local measurements with 150 indexed entries: result assembly was 8.2 µs before the change and 9.2 µs with both bundled command definitions. The release runner was 292,392 bytes; empty-helper launch plus Lua initialization had a 2.76 ms median over 15 launches. The running Caffeinate helper sampled 2,640 KiB RSS and 0.0% CPU. These are local measurements, not budgets for arbitrary author-controlled work or a comparison against other runtimes.
