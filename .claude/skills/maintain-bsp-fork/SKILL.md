---
name: maintain-bsp-fork
description: Maintain the junikimm717/AeroSpace BSP fork - sync with upstream nikitabobko/AeroSpace, test, build/install it on the user's Mac, and walk the user through macOS self-signing, keychain and Accessibility prompts. Use when asked to update/sync/rebuild/reinstall the fork, when AeroSpace stops responding after an install, or when codesign/Accessibility/Xcode problems come up.
---

# Maintaining the BSP fork

This repo is a fork of [nikitabobko/AeroSpace](https://github.com/nikitabobko/AeroSpace) that adds
bspwm-style tiling (`tiling-insertion-mode = 'bsp'`). All fork work lives on the `bsp` branch, which is
the fork's default branch on GitHub. `main` just mirrors upstream.

| Remote     | URL                                       |
|------------|-------------------------------------------|
| `origin`   | `git@github.com:junikimm717/AeroSpace.git` |
| `upstream` | `git@github.com:nikitabobko/AeroSpace`     |

If the remotes look different (fresh clone), fix them first:
`git remote add upstream git@github.com:nikitabobko/AeroSpace`.

## Where the BSP code lives

Keep the fork's diff small and self-contained so upstream syncs stay painless.

- `Sources/AppBundle/tree/tilingInsertion.swift` - all the BSP logic (`tilingInsertionPoint`, `bspSplit`,
  `insertTilingWindow`, split-orientation choice). New BSP behaviour goes here.
- Call sites that switch on `config.tilingInsertionMode` (the usual conflict hotspots on sync):
  `tree/MacWindow.swift` (new window placement), `command/impl/MoveCommand.swift`,
  `MoveNodeToWorkspaceCommand.swift`, `MoveNodeToMonitorCommand.swift`,
  `FlattenWorkspaceTreeCommand.swift`, `mouse/moveWithMouse.swift`.
- Config: `config/Config.swift`, `config/parseConfig.swift`. `bsp` forces
  `enable-normalization-flatten-containers = true` and
  `enable-normalization-opposite-orientation-for-nested-containers = false`, warning if the config disagrees.
- Tests: `Sources/AppBundleTests/tree/BspInsertionTest.swift`, BSP cases in `config/ConfigTest.swift`.
- Docs: `docs/guide.adoc#tiling-insertion-mode`, `docs/config-examples/bsp-config-example.toml`.

The default stays `'i3'`, so upstream behaviour is unchanged unless the user opts in. Keep it that way.

## Syncing with upstream

```bash
git fetch upstream
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout bsp && git rebase upstream/main
```

When resolving conflicts, keep upstream's change and re-apply the `switch config.tilingInsertionMode`
branch on top, rather than the other way around. If upstream changes how new windows get bound
(look at `unbindAndGetBindingDataForNewTilingWindow` / `runOnWindowDetected` in `MacWindow.swift`),
make sure placement still goes through `tilingInsertionPoint(in:)`.

Then run the tests (below), and push with `git push --force-with-lease origin bsp` (a rebase rewrites history).
Ask the user before force-pushing.

## Environment quirks on the user's Mac

Every build/test command needs a few environment fixes:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # xcode-select points at CommandLineTools
export PATH=/opt/homebrew/opt/ruby@3.4/bin:/opt/homebrew/bin:$PATH # docs need Ruby 3.x; Homebrew's default is 4.x
```

- **`DEVELOPER_DIR`**: without it, there's no XCTest (`unable to resolve module dependency: 'XCTest'`) and no `xcodebuild`.
  Don't change `xcode-select` on the user's behalf.
- **Ruby**: the `Gemfile` pins `ruby '~> 3.0'`. `ruby@3.4` is keg-only, so it doesn't change the user's default `ruby`.
- **complgen** (shell completions) fails with `feature 'edition2024' is required` on the user's older Cargo.
  Pre-install it with its lockfile instead of upgrading their Rust:
  ```bash
  rev=$(grep -o 'complgen_rev=[0-9a-f]*' script/install-dep.sh | cut -d= -f2)
  cargo install --locked --git https://github.com/adaszko/complgen --rev $rev --root ./.deps/cargo-root
  m=".deps/markers/complgen/$(echo "complgen $rev" | shasum | awk '{print $1}').marker"
  mkdir -p "$(dirname "$m")" && touch "$m"
  ```
- **`fish`** must be installed (`brew install fish`). `build-shell-completion.sh` syntax-checks the fish script.
- **Xcode errors** like `Symbol not found: _XPCTypeBool ... CoreDevice` mean Xcode's system components are
  out of date, which usually happens after a macOS or Xcode update. Run Xcode's first-launch install (needs admin; see below):
  `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -runFirstLaunch`

### Running anything with sudo

The `! cmd` prompt prefix has no TTY, so `sudo` fails with "a terminal is required to read the password".
Use the native macOS password dialog instead, and tell the user it's about to pop up:

```bash
osascript -e 'do shell script "<command> 2>&1" with administrator privileges'
```

## Testing

```bash
./swift-test.sh                                    # full suite (with the env above)
swift test --filter 'BspInsertionTest|ConfigTest'  # just the fork's tests
```

### Live testing without touching the installed app

1. Copy the user's config to the scratchpad, and add the keys under test **near the top, before any `[table]`**.
   Keys appended to the end of the file land inside the last table (e.g. `[mode.service.binding]`), and
   AeroSpace reports them as unparseable key bindings.
   Remove `after-startup-command` entries (e.g. `borders`, `sketchybar`) so they don't start twice.
2. `osascript -e 'quit app "AeroSpace"'`, then run `./build-debug.sh` and
   `./.debug/AeroSpaceApp --config-path <copy>` in the background. Use `./.debug/aerospace` as the CLI.
3. Switch to an empty workspace and open throwaway windows
   (`osascript -e 'tell application "TextEdit" to make new document'`). There's no tree-dump command, so read the
   geometry with `tell application "TextEdit" to get bounds of every window` and infer the tree from it.
4. Restore afterwards: close the test windows, run `pkill -f .debug/AeroSpaceApp`, then `open -a AeroSpace`.

Ask before swapping out the user's running window manager.

## Building and installing for the user

```bash
./install-from-sources.sh   # with the env above. Takes several minutes.
```

This builds a signed release, uninstalls any `aerospace` cask, installs `.release/aerospace-dev.rb` as the
`aerospace-dev` cask, and puts `AeroSpace.app` in `/Applications`. Afterwards, the already-running server is still
the old binary (`client and server versions are incompatible`), so restart it:

```bash
osascript -e 'quit app "AeroSpace"'; pkill -f /Applications/AeroSpace.app/Contents/MacOS/AeroSpace; open -a AeroSpace
aerospace --version   # both lines should show 0.0.0-SNAPSHOT <bsp HEAD sha>
```

If the server doesn't answer after a few seconds (`Connection refused`) while the process is running, it's
waiting for Accessibility. See the next section.

## Guiding the user through signing and Accessibility

macOS ties Accessibility permission to the app's code signature. Each step below needs the user's hands.
Give one clear instruction at a time, and verify each step yourself before moving on.

### 1. Self-signed code-signing certificate (one-time)

Check: `security find-identity -p codesigning`. It should list `aerospace-codesign-certificate`.
It shows up under "0 valid identities" because it's self-signed and untrusted. **That's fine**; codesign still
uses it. Don't make the user trust it.

If it's missing, have the user create it:
- Keychain Access → menu **Keychain Access → Certificate Assistant → Create a Certificate…**
- Name: `aerospace-codesign-certificate` (exactly this; `build-release.sh` uses it by name)
- Identity Type: **Self-Signed Root**
- Certificate Type: **Code Signing**

Signing with a stable certificate keeps the signature the same across rebuilds, so Accessibility permission
survives reinstalls. Ad-hoc signing (`-`) would force a re-grant after every build. Avoid it.

### 2. Keychain "codesign wants to use the key" prompt

The first `codesign` with a new certificate blocks on a keychain dialog, and the command appears to hang.
Before the build, warn the user: *"A keychain prompt will appear. Enter your login password and click
**Always Allow**, otherwise every build will ask again."* To surface it early, sign a throwaway file:

```bash
cp /bin/echo "$SCRATCH/echo-test" && codesign -f -s aerospace-codesign-certificate "$SCRATCH/echo-test" && codesign -v "$SCRATCH/echo-test"
```

Run it in the background if needed, and poll for completion instead of letting it time out.

### 3. Accessibility permission

AeroSpace waits silently, without serving the CLI socket, until it has Accessibility. Required:
- the **first time** the fork's build replaces the official cask (different signer: nikitabobko vs. the user's certificate);
- after the certificate gets **recreated** (new key, new signature);
- sometimes after macOS updates.

Not normally required when rebuilding with the same certificate.

Tell the user:
1. **System Settings → Privacy & Security → Accessibility**
2. If there's an existing **AeroSpace** entry, remove it with **–**. A stale entry for the old signature
   looks enabled but doesn't work, and toggling it does nothing.
3. Enable the new AeroSpace entry. If it isn't listed, use **+** to add `/Applications/AeroSpace.app`.

Then check with `aerospace list-windows --all`. If it still refuses connections, restart the app once
(`osascript -e 'quit app "AeroSpace"'; open -a AeroSpace`).

The debug build (`.debug/AeroSpaceApp`) launched from the terminal inherits the terminal's Accessibility grant,
so live testing normally needs no extra permission.

## User config notes

- The user's config is `~/.config/aerospace/aerospace.toml` (still `config-version = 1`; its warning is
  unrelated to BSP). BSP keys must sit at the top level, above any `[table]`.
- Back up the config before editing it (`cp aerospace.toml aerospace.toml.bak-<reason>`), then run
  `aerospace reload-config`, which prints errors and warnings.
- Already-open windows keep their layout after enabling BSP. `aerospace flatten-workspace-tree` rebuilds a
  workspace as a balanced BSP tree.
- The user wants literal bspwm behaviour. Directional window moves are bound to `swap <dir>` (bspwm's
  `node -s`: trade places, tree shape unchanged, no-op at the edge), not `move`. Don't rebind them to `move`.
