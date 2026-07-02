# FA Lua Language Server — Build & Maintenance Skill

This skill covers building, patching, and maintaining the FA-specific patches to the
LuaLS language server for Supreme Commander: Forged Alliance development.

---

## Architecture Overview

```
lua-language-server/
  bin/lua-language-server[.exe]   Lua 5.5 VM + bee.lua C extensions, compiled binary
  bin/main.lua                    Bootstrap: loaded by the binary on startup
  script/                         ALL language server logic — pure Lua, loaded at runtime
  meta/3rd/fa/                    FA game engine type library
  3rd/bee.lua/                    C++ platform I/O library (submodule)
  3rd/luamake/                    Build system (submodule)
  3rd/EmmyLuaCodeStyle/           Code formatter (submodule)
  3rd/lpeglabel/                  PEG parser (submodule)
```

**Critical:** The binary is just a Lua VM. All language server logic is in `script/*.lua`,
loaded from disk at runtime. Patching `.lua` files does NOT require rebuilding the binary.
Only modify the C++ layer when you need new native symbols.

---

## FA Patch Files

| File | FA Change |
|---|---|
| `script/parser/compile.lua` | `hasExportEnv` flag; `.export = true` on top-level globals/functions |
| `script/parser/guide.lua` | `isExportEnv(state)` reads per-file `---@export-env` / `---@declare-global`; `getFunctionSelfNode(func)` — resolves `self` inside a table-literal method to the enclosing class table (see below) |
| `script/config/template.lua` | Registers the `Lua.runtime.exportEnvDefault` config key |
| `script/files.lua` | Passes `exportEnvDefault` from config to compiler options |
| `script/vm/compiler.lua` | Uses `getFunctionSelfNode` for un-annotated `self`; **`vm.getClassFields` now also merges fields from the FA class-factory call-sugar pattern** (`Factory(Base) { ... }`) — see below |
| `locale/en-us/setting.lua` | Description for `exportEnvDefault` (note: `disableScheme` / `supportScheme` strings already exist in *stock* LuaLS and are not FA additions) |
| `meta/3rd/fa-lib/config.json` | 3rd-party library config: sets `Lua.runtime.version = "LuaFA"`, registers `moho` as a global, and disables the `inject-field` diagnostic |

> **Corrected from an earlier draft of this doc:** previous versions of this file described
> patches to `script/brave/brave.lua`, `script/brave/work.lua`, `script/provider/diagnostic.lua`,
> `script/provider/provider.lua`, `script/core/diagnostics/undefined-field.lua`, and
> `meta/3rd/fa/config.lua`. **None of those files exist in this patch package** — they were
> either never implemented or lost from an earlier snapshot. `disableScheme`/`supportScheme`
> are in fact stock LuaLS settings, not FA additions, and were never wired to anything FA-specific.
> The `undefined-field`-inside-`__init` and `inject-field` sections below have been rewritten
> to describe what is *actually* in this package, plus a real fix for the `__init` bug that
> was previously only documented as a TODO.

---

## FA Class System: `__init` and `inject-field` Diagnostics

### `undefined-field` on sibling-method calls (e.g. inside `__init`)

**Symptom:**
```
Undefined field `SetupDragHandles`. Lua Diagnostics.(undefined-field)
(field) UIChatInterface.SetupDragHandles: unknown
```
fired on `self:SetupDragHandles()` (or any sibling-method call) inside `__init`, `__post_init`,
or any other method — **specifically when that method carries an explicit**
**`---@param self UIChatInterface` doc comment** (FA's own code style annotates `self` this way
almost everywhere, so this bug fires very broadly in practice).

**Root cause (confirmed by tracing `vm.getClassFields` in `script/vm/compiler.lua`):**
`UIChatInterface` is declared as `---@class UIChatInterface : Window` immediately above
`local ChatInterface = ClassUI(Window) { __init = ..., SetupDragHandles = ..., ... }`.
When LuaLS resolves the fields of a `---@class`, it looks at `set.bindSource.value`
(the expression initializing the annotated local) and merges in that expression's own
fields — but stock LuaLS **only recognizes two shapes** for that expression:
1. a bare table constructor: `local X = { ... }`
2. `local X = setmetatable({ ... }, mt)`

`ClassUI(Window) { ... }` is neither — it's `(ClassUI(Window))({ ... })`, a plain function
call whose sole argument happens to be the spec table. Stock LuaLS's merge logic never
matches this shape, so `UIChatInterface`'s field set falls back to *only* the explicit
`---@field` entries in the class doc comment — which, in FA's ported meta stubs, never
include methods. `SetupDragHandles` genuinely isn't part of the class as LuaLS sees it,
hence "undefined field."

This is independent of *ordering* inside the table literal — even fields defined earlier
than `__init` are invisible, because the merge never happens at all in this shape, not
because of a definition-order limitation. (The `getFunctionSelfNode` patch in
`parser/guide.lua` / `vm/compiler.lua` *does* correctly resolve `self` for methods that
have **no** explicit `---@param self X` annotation, by typing `self` from the call
expression directly, which does carry the full generic-inferred field set. But an explicit
`---@param self UIChatInterface` overrides that inference back to the incomplete nominal
class, which is why the bug still shows up constantly in code that follows FA's
convention of always annotating `self`.)

**Fix (implemented in this package):** `vm.getClassFields` in `script/vm/compiler.lua` now
has a third branch alongside the bare-table and `setmetatable` cases: if the bound
expression is a call whose *last argument* is a table literal, that table is merged as the
class's fields, regardless of which function is being called. This covers
`Class{...}`, `ClassUI(Base){...}`, `ClassShield(Base){...}`, `State{...}`, etc. uniformly,
and resolves fields from the whole table regardless of textual position — so order relative
to `__init` genuinely no longer matters, and no diagnostic-suppression band-aid is needed;
`UIChatInterface` now actually *has* `SetupDragHandles` as a known field, and a genuine typo
(e.g. `self:SetuDragHandles()`) will still correctly report `undefined-field`.

**Patch file:** `patches/script_vm_compiler.lua.patch` (regenerated; now contains both the
`getFunctionSelfNode` hunk and the `getClassFields` hunk).

---

### `inject-field` on engine-typed objects

**Symptom:**
```
Fields cannot be injected into the reference of `Bitmap` for `textures`.
To do so, use `---@class` for `UIChatInterface.DragTL`. Lua Diagnostics.(inject-field)
```

**Root cause:** FA code routinely stores extra Lua-side state on engine-typed objects:
```lua
self.DragTL          = Bitmap(self)       -- DragTL : bitmap_methods (engine type)
self.DragTL.textures = DragHandleTextures('ul')  -- inject-field fires here
```
`DragTL` resolves to `Bitmap` (from the FA stubs). `inject-field` fires because `textures`
is not declared as a `---@field` on `Bitmap`, and the engine C++ class is closed. This is
not an error — FA uses this pattern everywhere — and the diagnostic adds no value in an
FA codebase.

**Fix that is actually shipped:** `meta/3rd/fa-lib/config.json` (not `config.lua` — that
file never existed) already contains:
```json
"Lua.diagnostics.disable": [ "inject-field" ]
```
This is correct and, once the `fa-lib` 3rd-party library is actually *applied* to a
workspace, it disables `inject-field` globally for that workspace via the standard
`Config3rdParty` → `apply3rd` mechanism (`action = 'add'` onto `Lua.diagnostics.disable`).

**Why the screenshot still shows it firing:** a 3rd-party library's `config.json` only
takes effect once VS Code / the client "applies" it — either the user accepted the
"still queries" popup, `Lua.workspace.checkThirdParty` is set to `"Apply"`, or the words
in `cfg.words` are matched against open file text via `check3rdByWords`/`wholeMatch`. That
last path has a real bug: `wholeMatch` requires the *entire* matched capture to be an empty
string —
```lua
local function wholeMatch(a, b)
    local captures = { a:match(b) }
    return captures[1] == '' and captures[#captures] == ''
end
```
Tested directly against Lua 5.4: neither the FA config's `"words": ["."]` nor even LuaLS's
*own* documented example word pattern (`require[%s%(\"']+MAA[%)\"']`) ever satisfies this —
`a:match(b)` returns the matched substring itself when `b` has no capture groups, which is
never `''` for a real match. This is stock (unpatched-by-FA) LuaLS code, so it isn't
something this package can safely patch, but it does mean **auto-detection of `fa-lib`
should not be relied on** — if `checkThirdParty` isn't set to `"Apply"`, the popup was
dismissed, or was never shown, none of `fa-lib/config.json`'s settings apply, including the
`inject-field` disable, the `moho` global, and `Lua.runtime.version = "LuaFA"` itself.

**Reliable workaround:** set these directly in the project's own `.luarc.json` /
`.vscode/settings.json` rather than relying on auto-detection:
```json
{
  "Lua.workspace.library": ["<path-to-lua-language-server>/meta/3rd/fa-lib/library"],
  "Lua.runtime.version": "LuaFA",
  "Lua.diagnostics.globals": ["moho"],
  "Lua.diagnostics.disable": ["inject-field"],
  "Lua.runtime.nonstandardSymbol": ["continue", "!="],
  "Lua.runtime.exportEnvDefault": true
}
```

---

### `table` not resolving in `table.getn` (and other FA stdlib overrides)

`meta/3rd/fa-lib/library/stdlib/table.lua` adds `table.getn` (removed from stock Lua by
5.2, but present in FA's runtime) as an augmentation onto the *existing* `table` global —
it does not redeclare `table` itself, which is correct and mirrors how the official addons
extend built-in libraries. If `table.getn` (or `table` itself) isn't resolving, this is the
same root cause as the `inject-field` case above: `meta/3rd/fa-lib/library` never got added
to `Lua.workspace.library`, so none of FA's stdlib overrides are visible, and depending on
whether `Lua.runtime.version` also failed to apply as `"LuaFA"`, the workspace may be
falling back to a stock Lua 5.4/5.5 runtime, whose official meta doesn't define `table.getn`
at all (it was removed in 5.2). The `.luarc.json` snippet above should resolve this too. If
`table` itself (not just `.getn`) is still flagged as unrecognized after adding that config,
that would point to something more specific — worth sharing the exact diagnostic message/
hover text on `table` if it persists, since "table itself undefined" is a stronger symptom
than a missing-field warning and would need to be traced separately.

---


## The `_ENV = nil` Constraint

`script/parser/compile.lua` sets `_ENV = nil` at line 19. This is intentional sandboxing.

**Rule:** Every standard library function used in `compile.lua` must be captured as a
`local` upvalue **before** line 19. Calling any uncaptured name at runtime produces:

```
attempt to index a nil value (upvalue '_ENV')
```

at the call site — not at the definition. The error is misleading because Lua resolves
unknown names through `_ENV`, which is `nil`.

**Currently captured before `_ENV = nil`:**
```lua
local sbyte, sfind, smatch, sgsub, ssub, schar, supper  -- string.*
local uchar      = utf8.char
local tconcat    = table.concat
local tinsert    = table.insert
local tointeger  = math.tointeger
local tonumber   = tonumber
local maxinteger = math.maxinteger
local assert     = assert
```

**When adding new code to `compile.lua`**, check if it uses any of:
`ipairs`, `pairs`, `type`, `pcall`, `xpcall`, `error`, `select`, `unpack`,
`rawget`, `rawset`, `setmetatable`, `getmetatable`, `next`, `tostring`.

If so, add them to the pre-capture block before `_ENV = nil`.

---

## exportEnvDefault Implementation

The export-env system marks top-level globals with `.export = true` on their AST nodes.
It does NOT inject fake return statements or re-tag node types — doing so breaks the
document symbol provider, semantic token engine, and causes 3–7 second hangs.

**Correct approach:**
1. `guide.isExportEnv(state)` checks per-file comment directives vs config default
2. `compile.lua` calls it once at parse start: `State.hasExportEnv = guide.isExportEnv(State)`
3. `compileExpAsAction` sets `.export = true` on `getglobal` nodes at top chunk level
4. Function declaration handler in `parseAction` sets `.export = true` on `setglobal` nodes

**Wrong approaches (have been tried, all broke things):**
- Re-tagging `exp.type = 'local'` — breaks symbol provider
- Injecting `return { ... }` nodes with `start = -1` — breaks range-based queries
- Calling `pushActionIntoCurrentChunk` from inside `resolveName` — that function is
  defined 800 lines later; `_ENV = nil` makes it an uncaptured global → crash

---

## Region Folding

Upstream LuaLS natively supports `--#region` / `--#endregion` folding. No patches to
`folding.lua` or `highlight.lua` are required.

The FA `plugin.lua` preprocessor does **not** touch `--#region` lines: when scanning a
line, it detects the `--` at column 1 as a real comment start and stops — the `#` that
follows is already inside the comment and is left alone. So `--#region` reaches the
language server unchanged and LuaLS folds it normally.

A standalone `#region` at the start of a line (no leading `--`) is a valid FA-style
comment. The preprocessor replaces the `#` with `--`, making it `--region`. This is
treated as a regular comment; it will **not** trigger fold markers (use `--#region`
instead if you want foldable regions in FA code).

---

## Bitwise Operators (`<<`, `>>`, `&`, `|`, `^`)

FA's runtime (see [FAForever/lua-lang](https://github.com/FAForever/lua-lang)) adds
C-style bitwise operators. The LuaLS parser already has all five in `BinarySymbol` with
correct precedence:

```lua
['|']   = 4,   -- bitwise OR
['~']   = 5,   -- bitwise XOR (binary) / NOT (unary)
['&']   = 6,   -- bitwise AND
['<<']  = 7,   -- left shift
['>>']  = 7,   -- right shift
```

**Problem with `<<` and `>>`:** `parseBinaryOP` (compile.lua ~line 2983) has a version
guard that fires `UNSUPPORT_SYMBOL` for these two unless the version is `Lua 5.3/5.4/5.5`.
`LuaFA` was not in that allowlist.

**Fix:** Add `and State.version ~= 'LuaFA'` to the guard condition:

```lua
if token == '//'
or token == '<<'
or token == '>>' then
    if  State.version ~= 'Lua 5.3'
    and State.version ~= 'Lua 5.4'
    and State.version ~= 'Lua 5.5'
    -- FAForever: LuaFA supports bitwise << >> (see FAForever/lua-lang)
    and State.version ~= 'LuaFA' then
        pushError { type = 'UNSUPPORT_SYMBOL', ... }
    end
end
```

`&`, `|`, `~` (unary bitwise NOT) and `^` already had no version guard — they parse
without error under any version. Only `<<` and `>>` needed this fix.

**Patch file:** `patches/script_parser_compile.lua.patch` (new hunk at `@@ -2985 @@`)

---

## `plugin.lua` — `#` Preprocessor Bug Fix

**File:** `meta/3rd/fa-lib/plugin.lua`

**Symptom:** On a line like `local x = "a--b" # comment`, the `#` after the string
should be replaced with `--` (it is a FA-style comment). The old code called
`line:find("--", 1, true)` and found `--` at column 12 *inside the string*, then
treated `hash_pos > comment_pos` as "already in a comment" → the `#` was silently
dropped with no replacement.

**Root cause:** `line:find("--", 1, true)` is a plain substring search that cannot
distinguish `--` inside a string literal from a real Lua comment.

**Fix:** Walk the line character-by-character, honouring string literal spans:

```
State machine per character:
  ' or "  → enter string, skip to matching close-quote (handle \\ escapes)
  --      → found real comment start; record position and stop
  other   → advance
```

After finding the real `comment_pos` (or `nil` if no `--` comment exists outside
strings), the `#`-replacement logic is unchanged: replace every `#` that precedes
`comment_pos`, stop at the first `#` that follows it.

**Edge cases handled correctly after the fix:**

| Line                              | comment_pos | `#` replaced? |
|-----------------------------------|-------------|---------------|
| `# comment`                       | nil         | yes (col 1)   |
| `local x = 5 # comment`           | nil         | yes           |
| `-- real comment # hash`          | 1           | no            |
| `local s = "a--b" # comment`      | nil*        | yes           |
| `local s = "a--b" -- real # hash` | 20*         | no            |

_*`--` inside `"a--b"` is skipped; the scanner continues past the closing `"`._

**This file is shipped directly (no `.patch` file for it).** Update `plugin.lua` in
`meta/3rd/fa-lib/` directly.

---

## Build Procedure

### Linux/macOS binary

```sh
# 1. Clone the exact 3.18.2 tag (patches won't apply to other versions)
git clone --depth=1 --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server
git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel

# 2. Build luamake
cd 3rd/luamake && bash compile/build.sh && cd ../..

# 3. Build LuaLS + run full test suite
./3rd/luamake/luamake rebuild
# All tests must pass before packaging
```

### Windows binary (native, requires Visual Studio)

Open a plain **Command Prompt** — NOT Git Bash. `build.bat` must find MSVC via
`vswhere.exe`, and `build.sh` will fail on Windows with exit code 3221225785.

```bat
git submodule update --init --recursive
cd 3rd\luamake
compile\build.bat
cd ..\..\ 
3rd\luamake\luamake.exe rebuild
```

Requires: Visual Studio 2019+ (or Build Tools) with C++ workload, and ninja in PATH
(VS Developer Command Prompt adds it automatically).

Output: `bin/lua-language-server.exe` + DLLs in `bin/`.
The native build ships MSVC runtime DLLs (`msvcp140.dll`, `vcruntime140.dll`, etc.)
instead of `libwinpthread-1.dll`.

### Linux binary from Windows

Three options, in order of recommendation:

**WSL2** (simplest — follow the Linux build steps inside `wsl`):
```sh
# In WSL2 Ubuntu terminal
git clone --depth=1 --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server
# Apply patches, init submodules, then:
cd 3rd/luamake && bash compile/build.sh && cd ../..
./3rd/luamake/luamake rebuild
# Copy result to Windows: cp bin/lua-language-server /mnt/c/your/path/
```

**Docker Desktop** (one liner from PowerShell, no WSL2 required):
```powershell
docker run --rm -v "${PWD}:/work" -w /work ubuntu:22.04 bash -c "
    apt-get update -q && apt-get install -y -q gcc g++ ninja-build &&
    git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel &&
    cd 3rd/luamake && bash compile/build.sh && cd ../.. &&
    ./3rd/luamake/luamake rebuild
"
# bin/lua-language-server appears on the Windows host via volume mount
```

**GitHub Actions** (no local Linux at all): push the patched repo and download the
`linux-x64` artifact from the Actions tab. The existing `.github/workflows/build.yml`
builds all platforms.

### Windows binary (cross-compile from Linux, alternative)

**Requirement:** `x86_64-w64-mingw32-gcc` in posix threading model.

```sh
# Install
apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64

# Switch to posix model (required for C++ exception support across DLL boundaries)
update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

# Create case-redirect header shims (Linux FS is case-sensitive; bee.lua uses <Windows.h>)
mkdir -p build/win32-compat
echo '#include <windows.h>'  > build/win32-compat/Windows.h
echo '#include <dbghelp.h>'  > build/win32-compat/DbgHelp.h
echo '#include <ws2tcpip.h>' > build/win32-compat/Ws2tcpip.h
echo '#include <dbgeng.h>'   > build/win32-compat/DbgEng.h

# Create output dirs
mkdir -p build/win32/{obj/{source_bee,source_lua,lua-language-server,lpeglabel,source_bootstrap,code_format},bin}

# Build (uses the checked-in win32-cross-compile.ninja)
ninja -f win32-cross-compile.ninja all
```

**Runtime dependency check:**
```sh
x86_64-w64-mingw32-objdump -p build/win32/bin/lua-language-server.exe | grep "DLL Name"
# Expected: KERNEL32.dll, VERSION.dll, WS2_32.dll, ntdll.dll,
#           api-ms-win-core-synch-l1-2-0.dll, libwinpthread-1.dll, msvcrt.dll
```

Bundle `libwinpthread-1.dll` from `/usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll`.

### Regenerating win32-cross-compile.ninja for a new LuaLS version

After a new LuaLS version builds successfully on Linux, a new `build/build.ninja` is
generated. Transform it to a Windows cross-compile file with these substitutions:

| Linux | Windows |
|---|---|
| `cc = gcc` | `cc = x86_64-w64-mingw32-gcc` |
| `ar = ar` | `ar = x86_64-w64-mingw32-ar` |
| `builddir = build` | `builddir = build/win32` |
| `-DLUA_USE_LINUX` | `-D_WIN32_WINNT=0x0602` |
| Remove: `-fPIC`, `-fvisibility=hidden`, `-rdynamic` | |
| `bee/filewatch/filewatch_linux.cpp` | `bee/filewatch/filewatch_win.cpp` |
| `bee/net/bpoll_linux.cpp` | `bee/net/bpoll_win.cpp` |
| `bee/sys/path_linux.cpp` | `bee/sys/path_win.cpp` |
| `bee/subprocess/subprocess_posix.cpp` | `bee/subprocess/subprocess_win.cpp` |
| `bee/sys/file_handle_linux.cpp` | `bee/sys/file_handle_win.cpp` |
| `bee/thread/simplethread_posix.cpp` | `bee/thread/simplethread_win.cpp` |
| `binding/lua_epoll.cpp` | `binding/port/lua_windows.cpp` |
| Remove: `file_handle_posix.obj`, `path_posix.obj` from link step | |

**Add these Windows-only sources to build + link:**
```
3rd/bee.lua/bee/win/wtf8.cpp
3rd/bee.lua/bee/win/unicode.cpp
3rd/bee.lua/bee/win/module_version.cpp
3rd/bee.lua/bee/win/afd/afd.cpp
3rd/bee.lua/bee/win/afd/poller.cpp
3rd/bee.lua/bee/win/afd/poller_fd.cpp
3rd/bee.lua/bee/net/uds_win.cpp
3rd/bee.lua/3rd/lua-patch/bee_utf8_crt.cpp
3rd/bee.lua/bee/subprocess/process_select.cpp
```

**Link flags** (replace Linux flags entirely):
```
-Wl,-Bstatic <libstdc++.a> <libsupc++.a> <libgcc_eh.a> <libgcc.a> -Wl,-Bdynamic
-lws2_32 -lpsapi -liphlpapi -lwsock32 -lshlwapi -ldbghelp
-lole32 -luserenv -lbcrypt -lntdll -lversion -lsynchronization -s
```

Use explicit `.a` paths (e.g. `/usr/lib/gcc/x86_64-w64-mingw32/13-posix/libstdc++.a`)
rather than `-static-libstdc++` — the flag doesn't reliably find the right library in
the mingw directory layout.

**Output:** `lua-language-server.exe` (not `lua-language-server`)

**Remove** test steps (`unit-test`, `bee-test`) — cannot run `.exe` on Linux.

---

## Common Failures

### `attempt to index a nil value (upvalue '_ENV')` in compile.lua

A standard library function was called in `compile.lua` without being captured before
`_ENV = nil`. Add it to the pre-capture block at the top of the file.

Run `./3rd/luamake/luamake rebuild` to verify before packaging.

### `module 'bee.epoll' not found` on Windows

`script/brave/brave.lua` is **not included in this patch package** (verified: it's
byte-identical to stock LuaLS, which calls `require 'bee.epoll'` unconditionally at the
top of the file). This will fail on Windows, where only `bee.select` is available. This
needs a platform check but does not currently have one shipped in this snapshot:
```lua
if platform.os == 'windows' then
    poller_lib = require 'bee.select'   -- SELECT_READ flag
else
    poller_lib = require 'bee.epoll'    -- EPOLLIN flag
end
```
If you're building for Windows and hit this, this fix needs to be (re-)written and added
to `script/brave/brave.lua` plus a corresponding `patches/script_brave_brave.lua.patch`.

### Blank outline / grayed-out symbols

Caused by injecting synthetic AST nodes or re-tagging existing nodes' `.type` field
after they've been inserted into the tree. Only set `.export = true` on real nodes.
Never add nodes with `start = -1` / `finish = -1`.

### `bin/main.lua: No such file or directory`

`make/bootstrap.lua` must be copied to `server/bin/main.lua`. It is NOT the same as
`server/main.lua`.

### Windows exe exits with code 1

`libwinpthread-1.dll` is missing from `server/bin/`. Copy it from
`/usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll`.

### Ninja linker errors: `undefined reference to std::...`

The `-static-libstdc++` flag doesn't find the right library in the mingw posix layout.
Use explicit `.a` file paths in the link command instead.

---

## Updating to a New LuaLS Version

1. Clone the new release, init submodules.
2. Apply patches from `patches/*.patch` with `patch -p1`.
3. Verify these functions still exist with the same signatures:
   - `compileExpAsAction` in `compile.lua`
   - Function name handler block in `parseAction` in `compile.lua`
   - `vm.getClassFields` in `vm/compiler.lua` — specifically the `setmetatable`
     branch inside the `src.value.type == 'select' and src.value.vararg.type == 'call'`
     block, which our call-sugar branch sits directly after
   - `getFunctionSelfNode` usage in `vm/compiler.lua`'s self-node resolution, and its
     definition in `parser/guide.lua`
   - The `if token == '//' or token == '<<' or token == '>>'` block in `parseBinaryOP`
     in `compile.lua` — confirm our `and State.version ~= 'LuaFA'` line is still present
     and that LuaLS hasn't moved or restructured this version guard.
4. Run `./3rd/luamake/luamake rebuild` — all tests must pass.
5. Regenerate `win32-cross-compile.ninja` using the substitutions above.
6. Rebuild the Windows exe and verify DLL dependencies.
