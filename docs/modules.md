# Modules

```nifty
import io
import "graphics/window.nifty"
import "graphics/window.nifty" as display

type Window = window.Window
openWindow = display.open
```

The two path imports above share one module instance. `window` is the filename
without `.nifty`; `display` is another binding to the same module. A filename
that is not a valid identifier needs an explicit `as` alias. Each import occupies
its own line at the beginning of the file.

Imports cascade declarations and module bindings. For `app -> facade -> leaf`,
the app can use `leaf.name`, `facade.leaf.name`, or an unambiguous `name`.
Every declaration, including `_implementation` names, participates equally.
Underscores communicate intent without changing access or exports.

Declarations in the current file win over imported names. Routine overloads
merge by Nifty's existing first-argument dispatch kind; a local overload wins
over imported overloads with that same kind. Imported candidates never win by
being imported later. If two imported routines match, qualify the call or add
an alias. Conflicting constants, types, and values require the same treatment.
Unused ambiguous names do not prevent importing a module.
Generic routines retain Nifty's restriction against overload sets; qualify
or alias a generic name when it competes with another routine.

An explicit alias selects the original symbol. Function aliases preserve their
overloads and generics, type aliases preserve nominal identity, and global
aliases refer to the original storage and locks. Aliases do not bypass the
ownership checker. Module bindings are reserved against local declarations;
use `as` when a module name conflicts with the name you want to declare.

A module's internal calls resolve in its defining file. An application defining
its own `combine` cannot replace a helper used inside an imported module.
The compiler resolves scopes before its existing whole-program safety checks,
then emits one C, native, or WebAssembly program.

Local files resolve relative to the importing file, with standard-library lookup
as a fallback for bare imports. The module's normalized absolute path identifies
it; `import helper`, `import "helper.nifty"` and `import "./helper.nifty"` share
one instance when they resolve to the same file. Symlinks are not resolved into
another file's identity. Different locations remain separate modules even when
their contents are identical. Import diamonds share globals, types, and threads.
Cycles produce a compile error with the import chain.

## URL source cache

```nifty
import "https://example.com/1.0.3/math.nifty" as math
```

The compiler uses `curl` for an uncached HTTP(S) download; generated programs
do not need curl or the module source. A URL is the module identity, so different
URLs remain separate instances even if they return identical contents.
Relative imports in a remote file resolve against that file's original URL
after checking for a local override. A bare remote import also searches the
standard library before fetching its sibling URL.

The first successful resolution writes SHA-256 pins to `nifty.lock` beside
the entry source. Commit this lockfile. Later builds verify cached or downloaded
source against those pins and reject changed or corrupted contents.
The cache retains pinned revisions, so updating the same URL in another
project does not invalidate an older project's offline build.

```text
nifty build app.nifty --offline
nifty build app.nifty --update-imports
```

Offline builds reuse cached source and reject a cache miss without downloading.
An explicit update refreshes the reachable URL graph and replaces its pins.
Offline and update modes cannot be used together for a URL import.

The source cache defaults to:

| Platform | Directory |
| --- | --- |
| Windows | `%LOCALAPPDATA%\Nifty\imports` |
| macOS | `~/Library/Caches/nifty/imports` |
| Linux | `$XDG_CACHE_HOME/nifty/imports`, falling back to `~/.cache/nifty/imports` |

`NIFTY_IMPORT_CACHE` overrides the cache directory. `NIFTY_OFFLINE=1` and
`NIFTY_UPDATE_IMPORTS=1` provide the corresponding modes for compiler embedding.
`NIFTY_STDLIB` selects a standard-library search directory. Downloads allow
HTTP and HTTPS, use the platform curl certificate checks, and have a 30-second
deadline and a 16 MiB source-file limit. URL fragments are rejected.
