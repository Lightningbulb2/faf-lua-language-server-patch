# FA Lua Language Server — Patches

This package contains the FA-specific patches applied to
[LuaLS](https://github.com/LuaLS/lua-language-server) v3.18.2
to support Supreme Commander: Forged Alliance development.

---

## FA-Specific Features

### `---@export-env` / `---@declare-global` Directives

Controlled by `Lua.runtime.exportEnvDefault` (set to `true` automatically by the FA type
library's `config.lua`).

FA scripts define module-level globals that other files access through the environment
rather than explicit `require`. These directives control how the server treats globals
per-file:

| Directive                                   | Effect                                                |
| ------------------------------------------- | ----------------------------------------------------- |
| _(no directive, `exportEnvDefault = true`)_ | All top-level globals treated as exported env symbols |
| `---@declare-global`                        | Opts this file **out** of export-env                  |
| `---@export-env`                            | Opts this file **in** when `exportEnvDefault = false` |
| `---@meta`                                  | Marks file as type-declaration; disables export-env   |

**Implementation:** `guide.lua` adds `isExportEnv(state)` which reads per-file comment
directives. `compile.lua` calls it once at parse start and sets `State.hasExportEnv`.
`compileExpAsAction` and the function-declaration handler in `parseAction` mark top-level
globals with `.export = true` when active. No AST nodes are added or re-typed.

### `--#region` / `-- #region` Code Folding

FA scripts use `--#region` (no space). The FA preprocessor plugin converts `#` to `--`,
so the comment text the folding provider sees is `--region` rather than `#region`.

`core/folding.lua` and `core/highlight.lua` both match all four variants:

| Input                | Comment text after preprocessing | Matched by                        |
| -------------------- | -------------------------------- | --------------------------------- |
| `-- #region`         | ` #region`                       | `#region` pattern                 |
| `--region`           | `region`                         | `region` pattern                  |
| `--#region`          | `--region`                       | `--region` pattern (FA-specific)  |
| `-- #region` (space) | ` -- region`                     | `-- region` pattern (FA-specific) |

### `LuaFA` Runtime Version

A new runtime version option that maps to Lua 5.1 semantics while removing deprecation
warnings from functions that are standard (not deprecated) in FA's custom runtime:

| Function               | Standard LuaLS (Lua 5.1) | LuaFA                               |
| ---------------------- | ------------------------ | ----------------------------------- |
| `table.getn(t)`        | ~~deprecated~~           | ✓ normal                            |
| `table.foreach(t, f)`  | ~~deprecated~~           | ~~deprecated~~ (use `for k,v in t`) |
| `table.foreachi(t, f)` | ~~deprecated~~           | ~~deprecated~~                      |
| `table.empty(t)`       | unknown                  | ✓ FA extension                      |
| `table.getsize(t)`     | unknown                  | ✓ FA extension                      |
| `continue` keyword     | error                    | ✓ via nonstandardSymbol             |
| `!=` operator          | error                    | ✓ via nonstandardSymbol             |
| `arg` implicit vararg  | undefined-global         | ✓ declared as global                |

Set automatically by the FA `config.lua` when any `.lua` file is opened. Can be
set manually via `Lua.runtime.version = "LuaFA"`.

### FA Class System (`class.lua`)

The FA class system uses several Lua 5.0-era features that the LS needs to handle:

**`{&N &M}` table size hints** — FA's engine extends the Lua table constructor syntax
with pre-allocation hints: `{&1 &0}` means "1 hash slot, 0 array slots". These are
invalid in standard Lua. `plugin.lua` now strips them during preprocessing so the parser
sees `{}` instead.

**`arg` implicit vararg table** — In Lua 5.0, vararg functions receive arguments as
`arg = {..., n=N}` rather than `...`. FA's class system uses `unpack(arg)` throughout.
`config.lua` now declares `arg` as a known global to suppress undefined-global warnings.

**`Class(...)` / `State(...)` / `ConstructClass(...)` types** — The class system file
(`class.lua`) is included in the FA library so the LS understands the `fa-class` and
`fa-class-state` types, including the callable `__call` metamethod pattern.

### `__init` / `__post_init`: no `undefined-field` for sibling methods

Inside `__init` (and `__post_init`) FA code calls methods defined on the **same** class
table:

```lua
local ChatInterface = ClassUI(Window) {
    ---@param self UIChatInterface
    __init = function(self, parent)
        self:SetupDragHandles()      -- ← was: undefined-field false positive
    end,
    SetupDragHandles = function(self) ... end,
}
```

When the user annotates `---@param self UIChatInterface`, LuaLS resolves the type
through a separately-declared `---@class` annotation. That declaration may not list
every method from the class table literal, so `SetupDragHandles` resolves as `unknown`.

**Fix:** `script/core/diagnostics/undefined-field.lua` — a small `isInsideFAInit(src)`
helper walks the AST upward: `getfield`/`getmethod` → `getParentFunction` →
`function.parent` (the `tablefield` node) → checks the key is `__init` or
`__post_init`. If so, the `undefined-field` check is skipped.

Only the two init-method names are suppressed; all other function bodies and top-level
code are unaffected.

---

### `inject-field` disabled for FA engine-typed objects

FA code routinely attaches extra Lua-side state to engine-typed objects:

```lua
self.DragTL          = Bitmap(self)
self.DragTL.textures = DragHandleTextures('ul')   -- was: inject-field
```

`Bitmap` is an engine C++ type exposed through FA stubs. The engine does not prevent
field injection — Lua's metatable system allows it freely — but LuaLS fires
`inject-field` because `textures` is not declared as a `---@field` on `Bitmap`.
Annotating every such site across thousands of FA files would add thousands of
`---@class`-override casts with no meaningful benefit.

**Fix:** `meta/3rd/fa/config.lua` — `inject-field` added to `Lua.diagnostics.disable`
for all FA workspace files.

---

### Named Color Picker

The document color provider (`core/color.lua`) is replaced with the FA version which
recognises FA's named color constants in addition to hex strings:

| Format                 | Example           | Supported        |
| ---------------------- | ----------------- | ---------------- |
| 8-digit hex (AARRGGBB) | `"BD8608FF"`      | ✓                |
| 6-digit hex (#RRGGBB)  | `"#BD8608"`       | ✓                |
| FA named color         | `"DarkGoldenrod"` | ✓ (FA extension) |

Named colors come from FA's `EnumColorNames` table and cover ~140 standard CSS colors
remapped to FA's AARRGGBB byte order.

### `Lua.diagnostics.disableScheme`

Suppresses diagnostics on files matching certain URI schemes. Default: `['git']`.
Prevents errors appearing in VS Code's read-only git diff views.

### `Lua.workspace.supportScheme`

Restricts which URI schemes the server accepts for `didOpen` / `didChange`. Default:
`['file', 'untitled', 'git']`. Files with other schemes are silently ignored.

### Platform-Aware Event Loop (`brave.lua`)

The worker event loop uses `bee.epoll` on Linux/macOS and `bee.select` on Windows:

```lua
if platform.os == 'windows' then
    poller_lib = require 'bee.select'
    POLLIN     = poller_lib.SELECT_READ
else
    poller_lib = require 'bee.epoll'
    POLLIN     = poller_lib.EPOLLIN
end
```

Both modules share the same `create()` / `event_add(fd, flags)` / `wait()` API.
`bee.select.create()` takes no arguments; `bee.epoll.create(n)` takes a max-events hint.

---

## What's in this package

```
script/
  brave/brave.lua            Platform-aware event loop (bee.select on Windows, bee.epoll on Linux)
  brave/work.lua             Compile options type annotation (adds exportEnvDefault field)
  config/template.lua        Three new config keys: exportEnvDefault, disableScheme, supportScheme
  core/folding.lua           --#region / -- #region folding support
  core/highlight.lua         --#region / -- #region document highlight support
  core/diagnostics/
    undefined-field.lua      Suppress undefined-field inside __init / __post_init bodies
  files.lua                  Passes exportEnvDefault from config into the parser
  parser/compile.lua         exportEnvDefault parser integration; export flag on globals
  parser/guide.lua           isExportEnv(state) function
  provider/diagnostic.lua    disableScheme filtering
  provider/provider.lua      supportScheme filtering on didOpen / didChange

locale/en-us/setting.lua     English descriptions for the three new settings

patches/                     Unified diffs against unmodified LuaLS 3.18.2
  script_brave_brave.lua.patch
  script_brave_work.lua.patch
  script_config_template.lua.patch
  script_core_folding.lua.patch
  script_core_highlight.lua.patch
  script_files.lua.patch
  script_parser_compile.lua.patch
  script_parser_guide.lua.patch
  script_provider_diagnostic.lua.patch
  script_provider_provider.lua.patch
  locale_en-us_setting.lua.patch
  script_core_diagnostics_undefined-field.lua.patch
  meta_3rd_fa_config.lua.patch

win32-cross-compile.ninja    Pre-generated ninja file for Windows cross-compilation from Linux
```

---

## Building

### Prerequisites

| Tool                             | Notes                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| Git                              | For cloning and submodule init                                                       |
| GCC ≥ 11                         | Linux native build                                                                   |
| ninja ≥ 1.10                     | `apt install ninja-build`                                                            |
| `x86_64-w64-mingw32-gcc` (posix) | Windows cross-compile only — `apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64` |

Switch mingw to the posix threading model (required for C++ exceptions):

```sh
update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix
```

### Step 1 — Clone LuaLS 3.18.2 and init submodules

> **Version matters.** These patches are generated against the exact `3.18.2` tag.
> Cloning `main`/HEAD will get a newer commit with different line numbers and the
> patches will fail to apply.

```sh
git clone --depth=1 --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server
git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel
```

### Step 2 — Apply patches

```sh
PATCHES=/path/to/this/package/patches

for p in "$PATCHES"/*.patch; do
    patch -p1 < "$p"
done
```

Or copy the full patched files directly (replacing the cloned versions):

```sh
SRC=/path/to/this/package
cp $SRC/script/brave/brave.lua            script/brave/brave.lua
cp $SRC/script/brave/work.lua             script/brave/work.lua
cp $SRC/script/config/template.lua        script/config/template.lua
cp $SRC/script/core/folding.lua           script/core/folding.lua
cp $SRC/script/core/highlight.lua         script/core/highlight.lua
cp $SRC/script/files.lua                  script/files.lua
cp $SRC/script/parser/compile.lua         script/parser/compile.lua
cp $SRC/script/parser/guide.lua           script/parser/guide.lua
cp $SRC/script/provider/diagnostic.lua    script/provider/diagnostic.lua
cp $SRC/script/provider/provider.lua      script/provider/provider.lua
cp $SRC/locale/en-us/setting.lua          locale/en-us/setting.lua
```

### Step 3 — Build luamake

**On Linux/macOS:**

```sh
cd 3rd/luamake
bash compile/build.sh
cd ../..
```

**On Windows** (requires Visual Studio 2019 or later, or Build Tools):

Open a **plain Command Prompt** (not Git Bash — `build.bat` must detect MSVC via
`vswhere.exe`):

```bat
cd 3rd\luamake
compile\build.bat
cd ..\..\
```

> `compile/build.sh` does **not** work on Windows — it targets the mingw compiler
> and will fail with exit code 3221225785 even if Git Bash is installed. Always use
> `compile\build.bat` on Windows.

Ninja must be in your PATH. Visual Studio's Developer Command Prompt includes it
automatically, or install it standalone: https://github.com/ninja-build/ninja/releases

If you get this error:

ninja: error: 'bee.lua/bootstrap/bootstrap.rc', needed by 'build/msvc/obj/luamake/bootstrap.obj', missing and no known rule to make it

Then do:

```
cd PATH/TO/THE/lua-language-server
git submodule update --init --recursive
```

### Step 4 — Build the binary

**On Linux/macOS:**

```sh
./3rd/luamake/luamake rebuild
```

**On Windows** (from a plain Command Prompt or VS Developer Command Prompt):

```bat
3rd\luamake\luamake.exe rebuild
```

This runs the full test suite. All tests must pass.

Output:

- Linux/macOS: `bin/lua-language-server`
- Windows: `bin/lua-language-server.exe` + `bin/lua-language-server.dll` + MSVC runtime DLLs

### Step 5 — Build the Windows binary from Linux (cross-compile, optional)

Only needed if you want to produce a Windows binary on a Linux host. Skip this if
you built natively on Windows in Step 4.

```sh
# Prerequisites: apt install gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
# Switch to posix threading model:
update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix
update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

# Create Windows.h case shims (Linux filesystem is case-sensitive)
mkdir -p build/win32-compat
echo '#include <windows.h>'  > build/win32-compat/Windows.h
echo '#include <dbghelp.h>'  > build/win32-compat/DbgHelp.h
echo '#include <ws2tcpip.h>' > build/win32-compat/Ws2tcpip.h
echo '#include <dbgeng.h>'   > build/win32-compat/DbgEng.h

# Create output directories
mkdir -p build/win32/{obj/{source_bee,source_lua,lua-language-server,lpeglabel,source_bootstrap,code_format},bin}

# Build using the cross-compile ninja file from this package
ninja -f /path/to/this/package/win32-cross-compile.ninja all
```

Output: `build/win32/bin/lua-language-server.exe`

The cross-compiled exe depends only on `libwinpthread-1.dll` (no MSVC runtime).
The natively-built Windows exe ships with MSVC runtime DLLs instead.

```sh
x86_64-w64-mingw32-objdump -p build/win32/bin/lua-language-server.exe | grep "DLL Name"
# KERNEL32.dll, VERSION.dll, WS2_32.dll, ntdll.dll, libwinpthread-1.dll, msvcrt.dll
```

---

## Building a Universal Package (all platforms from Windows)

The extension can bundle Linux, macOS, and Windows binaries in the same `.vsix` so users
on any OS install the same file. The Windows binary is easy (build natively). For the
Linux binary you have three options from a Windows host.

---

### Option A — WSL2 (recommended)

WSL2 runs a real Linux kernel on Windows with near-native performance. This is the
simplest path and uses the same Linux build steps exactly.

**One-time setup:**

```powershell
# In PowerShell (Admin)
wsl --install          # installs Ubuntu by default; reboot when prompted
wsl --set-default-version 2
```

Then open the Ubuntu terminal and install build tools:

```sh
sudo apt update
sudo apt install -y git gcc g++ ninja-build
```

**Build:**

```sh
# Inside WSL2 Ubuntu terminal
git clone --depth=1 --branch 3.18.2 https://github.com/LuaLS/lua-language-server
cd lua-language-server

# Apply FA patches (copy them from Windows into WSL2 first, or clone from your repo)
# Windows drives are at /mnt/c/, /mnt/d/, etc.
for p in /mnt/c/path/to/patches/script_*.patch /mnt/c/path/to/patches/locale_*.patch; do
    patch -p1 < "$p"
done

# Build luamake
git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel
cd 3rd/luamake && bash compile/build.sh && cd ../..

# Build LuaLS (runs tests)
./3rd/luamake/luamake rebuild
```

**Copy the binary to Windows:**

```sh
# From WSL2, copy to Windows filesystem
cp bin/lua-language-server /mnt/c/path/to/extension/server/bin/lua-language-server
cp bin/main.lua             /mnt/c/path/to/extension/server/bin/main.lua
```

---

### Option B — Docker Desktop

Docker Desktop runs Linux containers on Windows without WSL2 (though it also works
with WSL2 as backend).

**One-time setup:**
Download and install [Docker Desktop for Windows](https://www.docker.com/products/docker-desktop/).

**Build:**

```powershell
# In PowerShell, from the lua-language-server directory with FA patches already applied
docker run --rm -v "${PWD}:/work" -w /work ubuntu:22.04 bash -c "
    apt-get update -q && apt-get install -y -q git gcc g++ ninja-build &&
    git submodule update --init 3rd/luamake 3rd/bee.lua 3rd/EmmyLuaCodeStyle 3rd/lpeglabel &&
    cd 3rd/luamake && bash compile/build.sh && cd ../.. &&
    ./3rd/luamake/luamake rebuild
"
```

The `bin/lua-language-server` Linux binary will appear in your working directory on
Windows when the container exits (volume mount keeps the output).

---

### Option C — GitHub Actions (no local Linux at all)

If you don't want to install WSL2 or Docker, let CI build the Linux binary and
download the artifact.

1. Fork `LuaLS/lua-language-server` to your GitHub account.
2. Checkout the `3.18.2` tag and apply the FA patches.
3. Push to your fork (to a branch or tag).
4. The existing `.github/workflows/build.yml` will build for all platforms automatically.
5. Download the `linux-x64` artifact from the Actions tab.

The artifact contains `bin/lua-language-server` and all the Lua scripts — just take
`bin/lua-language-server` and `bin/main.lua` from it.

---

### Assembling the universal VSIX

Once you have binaries from all platforms, assemble `server/bin/` like this:

```
server/bin/
  main.lua                      ← from make/bootstrap.lua (same for all platforms)
  lua-language-server           ← Linux binary (from WSL2, Docker, or CI)
  lua-language-server.exe       ← Windows binary (built natively with MSVC)
  lua-language-server.dll       ← Windows (from native MSVC build)
  libwinpthread-1.dll           ← Windows (only if using mingw cross-compile)
  <other MSVC DLLs>             ← Windows (msvcp140.dll, vcruntime140.dll, etc.)
```

> If you built Windows natively with MSVC, copy ALL `.dll` files from `bin\` —
> the MSVC build links dynamically to the Visual C++ runtime. If you used the
> provided `win32-cross-compile.ninja` from Linux instead, you only need
> `libwinpthread-1.dll`.

The extension's `languageserver.ts` picks the right binary automatically:

```
Windows → lua-language-server.exe
Linux   → lua-language-server
macOS   → lua-language-server  (same name, different binary)
```

For a truly universal package you'd also want a macOS binary. That requires either
a Mac or a macOS CI runner — there's no practical cross-compiler for macOS from
Windows/Linux due to Apple's SDK licensing.

---

## Critical: The `_ENV = nil` Constraint

`script/parser/compile.lua` sets `_ENV = nil` at line 19 to prevent accidental global
access. Every standard library function used in that file must be captured as a `local`
upvalue **before** that line. Calling an uncaptured name produces:

```
attempt to index a nil value (upvalue '_ENV')
```

at the call site — not at the definition. This is misleading. When adding new code to
`compile.lua`, check whether it uses `ipairs`, `pairs`, `type`, `pcall`, `error`,
`tostring`, or similar. If so, add them to the pre-capture block:

```lua
local assert     = assert
-- add your captures here, before _ENV = nil
_ENV = nil
```

---

## FA Meta Library (`meta/3rd/fa/library`) (SLOPPY AND INCOMPLETE SECTION)

The FA library lives in the [`FAForever/fa`](https://github.com/FAForever/fa) game repo and must be copied in
separately. It contains many Lua type stub files covering the engine API.

### Initial setup (SLOPPY AND INCOMPLETE SECTION)

```sh
# From the lua-language-server root:
git clone --depth=1 https://github.com/FAForever/fa fa-game-repo
python3 -c "
import shutil, os

src = 'fa-game-repo/lua/'
dst = 'meta/3rd/fa/library/'

src2 = 'fa-game-repo/engine/'
dst = 'meta/3rd/fa/library/'

if os.path.exists(dst):
    shutil.rmtree(dst)
shutil.copytree(src, dst)
print('FA meta library installed:', sum(len(fs) for _,_,fs in os.walk(dst)), 'files')
"
```

Then overwrite with the FA-patch versions (plugin.lua, config.lua, and new stubs):

```sh
cp /path/to/this/package/meta/3rd/fa/plugin.lua meta/3rd/fa/plugin.lua
cp /path/to/this/package/meta/3rd/fa/config.lua meta/3rd/fa/config.lua
mkdir -p meta/3rd/fa/library/stdlib
cp /path/to/this/package/meta/3rd/fa/library/stdlib/table.lua meta/3rd/fa/library/stdlib/table.lua
mkdir -p meta/3rd/fa/library/engine
cp /path/to/this/package/meta/3rd/fa/library/engine/class.lua meta/3rd/fa/library/engine/class.lua
```

### Updating the FA library (SLOPPY AND INCOMPLETE SECTION)

When the FAF game repo updates its type stubs, pull the new version:

```sh
cd fa-game-repo && git pull && cd ..
python3 -c "
import shutil
shutil.rmtree('meta/3rd/fa')
shutil.copytree('fa-game-repo/lua/language-server/meta/3rd/fa', 'meta/3rd/fa')
"
# Re-apply the patch overrides
cp /path/to/this/package/meta/3rd/fa/plugin.lua  meta/3rd/fa/plugin.lua
cp /path/to/this/package/meta/3rd/fa/config.lua  meta/3rd/fa/config.lua
cp /path/to/this/package/meta/3rd/fa/library/stdlib/table.lua  meta/3rd/fa/library/stdlib/table.lua
cp /path/to/this/package/meta/3rd/fa/library/engine/class.lua  meta/3rd/fa/library/engine/class.lua
```

> **Note:** The FA game repo may be at a different path or use a different structure
> depending on the FAF release. The type stubs have historically lived at
> `lua/language-server/meta/3rd/fa/` in the fa repo.

---

## Updating to a New LuaLS Version

1. Clone the new tag and re-apply patches with `patch -p1`.
2. Check whether these functions were moved or renamed upstream:
   - `compileExpAsAction` in `compile.lua` — export flag injection point
   - Function name handler in `parseAction` in `compile.lua` — function export
   - `isValid` in `diagnostic.lua` — disableScheme injection point
   - `textDocument/didOpen` and `textDocument/didChange` in `provider.lua`
   - `comment.short` handler in `core/folding.lua` and `core/highlight.lua`
3. Run `./3rd/luamake/luamake rebuild` — all tests must pass.
4. Regenerate `win32-cross-compile.ninja` from the new `build/build.ninja` by applying
   the same source-file and linker-flag substitutions documented in the skill.
