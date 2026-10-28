# Draw posters

Draw a halftone poster (a PNG) with a coloured background, a small line of text and a large title, for example for the picture of a Jellyfin library.

Posters are an extension (package `posters`), off by default. Not tested on a server yet.

## Before you start
- The server has Pillow (the Python imaging library); `sudo hs rebuild` installs it.
- Switch the extension on (no rebuild needed for the commands):

```bash
sudo hs ext enable posters
```

`hs ext posters` lists all commands of the package. `hs ext list` shows whether it is on.

## Draw one, step by step

```bash
hs ext posters generate
```

The command asks: **eyebrow** (the small line above the title) and **title** (both required), colour, seed, and where to save (this folder, your home folder, a share from the list, or another folder). Leave colour and seed empty to get random ones; the colour is derived from the seed, so the same seed always draws the same poster. You can draw another with a new seed until one pleases you. At the end the command prints the line that draws exactly this poster again.

## Draw one in a single line
With options nothing is asked:

```bash
hs ext posters generate --eyebrow Library --title Films --color red --seed 5
```

| Option | Meaning |
| --- | --- |
| `--eyebrow <text>` | The small line above the title (required) |
| `--title <text>` | The title (required); a long title is made smaller, over about 30 characters it is refused |
| `--color <name\|#rrggbb>` | `red orange yellow green teal blue indigo purple pink` or a hex value; default random |
| `--seed <number>` | Decides where the halftone areas lie; default random |
| `--size <WxH>` | Default `1920x1080` (`768x432` is the size of a Jellyfin tile) |
| `--case upper\|keep` | Capital letters (default) or keep the spelling |
| `--out <file\|folder>` | A file, or an existing folder (then the default name `poster-<title>-<seed>.png`); default the current folder. An existing file stays unless you add `--force`. The file belongs to whoever owns the folder (for a share, the share owner), not root |

The machine-readable twin is `hs sys ext posters generate` (same options, never asks, prints `status`, `file`, `color`, `seed` and `size` line by line). The web interface uses it for its poster page.

## Get it to your computer
Save it into a share (choose "A share" in the dialog, or add `--out /bulk/shares/<share>`) and open it from your computer's file manager at `\\<server>\<share>`, or copy it with `scp`:

```bash
scp <server>:poster-films-5.png .
```

## Check that it worked
- The command prints `status ok` and a `file` path (with the `hs sys` form), and the file opens as an image.
- The same options and seed give the same poster.

## Turn it off

```bash
sudo hs ext disable posters
```

The commands disappear; posters you drew stay where you saved them.

## If something goes wrong
| Symptom | Cause | Fix |
| --- | --- | --- |
| `hs ext posters` says the extension is off | It is not enabled | `sudo hs ext enable posters` |
| `needs pillow` | The imaging library is missing | `sudo hs rebuild` |
| "Title too long" | More than about 30 characters | Shorten it |
| The file already exists | Overwriting needs `--force` | Add `--force` or choose another name |

## Next
- [Jellyfin: library pictures and your own discs](jellyfin.md)
