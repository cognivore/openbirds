# Asset workflow with git-annex

The `assets/` tree is a vendored library of purchased pixel-art packs.
Each pack ships as a directory with three kinds of file:

- `LICENSE` — the proprietary license terms (plain git, always visible).
- `README.md` — attribution and pack notes (plain git).
- everything else — sprites, tilesets, JSON metadata, sound (annexed).

The annexed bytes live in a private Google Drive bucket
(`gdrive:openbirds-annex/`) reached via an `rclone` external special
remote. A fresh clone only contains the symlinks; you have to `git
annex get` to materialise the content.

## Why git-annex

These packs are proprietary and may not be redistributed. Checking the
binaries into git would put them in every clone — including any public
fork — which we explicitly cannot do under the licenses. `git-annex`
gives us:

- content-addressed (SHA256E) keys, so two packs that ship the same
  PNG dedupe automatically;
- the binary store lives behind whatever remote you point at, and
  cloning the public repo does not pull it;
- the licence text *and* the file layout (which assets exist, where
  they live in the tree) stay browseable in plain git so we don't
  have to download 150 MB to find out which pack contains what.

The split between "track in git" and "track in annex" is encoded in
[`.gitattributes`](../../.gitattributes):

```
assets/** annex.largefiles=anything
assets/**/LICENSE annex.largefiles=nothing
assets/**/README.md annex.largefiles=nothing
```

## First-time setup on a new machine

1. Enter the dev shell so you get `git-annex`, `rclone`, and the
   `git-annex-remote-rclone` bridge from the flake:

   ```sh
   nix develop
   ```

2. Configure your `gdrive:` rclone remote (one-time, interactive
   OAuth):

   ```sh
   rclone config
   ```

   The remote name must be `gdrive` — that's the `target=` baked into
   the special-remote config when it was initialised. The account must
   have read access to the bucket the maintainer published to
   (`openbirds-annex/` under the maintainer's Drive root).

3. Initialise the annex in this clone and hook up the recorded special
   remote:

   ```sh
   git annex init "$(whoami)@$(hostname -s)"
   git annex enableremote gdrive
   ```

4. Fetch content:

   ```sh
   git annex get assets/                              # everything
   git annex get assets/2d-pixel-art-cat-sprites/     # one pack
   ```

## Inspecting where content lives

```sh
git annex whereis assets/2d-pixel-art-cat-sprites/Cat\ Sprite\ Sheet.png
git annex info
git annex list assets/
```

## Adding a new pack

Drop the pack directory under `assets/<slug>/` with its `LICENSE` and
`README.md` at the top. Then:

```sh
git annex add assets/<slug>/
git annex copy --to=gdrive assets/<slug>/
git commit -m "assets: <slug>"
git push origin main git-annex
```

The `git-annex` branch carries the annex metadata; without pushing it
the symlinks on other machines will not know which keys to ask for.

## Freeing local disk space

`git-annex` holds full file content under `.git/annex/objects/`. To
free space while keeping the symlinks:

```sh
git annex drop assets/
```

This only drops content git-annex can confirm is mirrored elsewhere
(here that means present on `gdrive`). If you've added a file but not
copied it to `gdrive` yet, `drop` will refuse.

## Troubleshooting

**`git annex enableremote gdrive` complains about a missing rclone
target.** Run `rclone listremotes` — the bridge needs an rclone remote
literally named `gdrive`. If your local rclone remote has a different
name, either rename it (`rclone config rename oldname gdrive`) or
re-init the special remote with the right `target=`.

**`git annex get` hangs or 403s on every file.** Check
`rclone ls gdrive:openbirds-annex/` works at all — most likely your
OAuth token expired (`rclone config reconnect gdrive:`) or you don't
have access to the bucket.

**Origin shows `setting annex-ignore`.** Expected. GitHub doesn't run
`git-annex-shell`, so we never try to push annex content there — the
`gdrive` remote is the one that actually holds bytes. The `git-annex`
*branch* (metadata only) still gets pushed to GitHub by `git push
origin main git-annex`.
