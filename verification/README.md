# Verification workspaces

Regression repros for the FA patches. Run with a built server binary:

    ./bin/lua-language-server --check <workspace-dir> --checklevel=Information

after replacing `<path-to>` in each workspace's `.luarc.json` with the absolute
path to this package's `meta/3rd/fa-lib/library`.

- `ws-stdlib-forwardref/` — must report **0 problems**. Covers: builtin stdlib under
  export-env (`string.format`, `table.getn` undeprecated), forward references to
  module functions declared later in the file, `math.mod`, `unpack`, `string.gfind`,
  `table.foreach(i)`, `table.setn`.
- `ws-class-selffields/` — must report **0 problems** (with `inject-field` disabled,
  as fa-lib's config does). Covers: call-sugar sibling methods (`self:SetupThing()`),
  and parent-class dynamic fields (`self.StartSizing(...)` where `Window.__init`
  assigns it) resolving through `---@class X : Window` + `---@param self X`.
- `foldtest.lua` — folding regression harness; run as
  `./bin/lua-language-server verification/foldtest.lua` from the server root (it
  follows `test.lua`'s bootstrap). Prints computed folding ranges through the real
  provider line-conversion for the three upstream issues (#2581, #3220, #2552) plus
  control cases. The #2552 output must match the clean control case, and no
  `comment`-kind fold may cover a declaration line.

- `ws-deprecation/` — `table.getn` / `foreach` / `foreachi` must **not** be flagged
  `deprecated` even in the `userThirdParty` layout where fa-lib's `stdlib/*.lua`
  overrides don't load (the fix is in `script/library.lua`'s meta generation, so it's
  config-independent). `table.move` (5.3+) *should* still be flagged — that's correct.
