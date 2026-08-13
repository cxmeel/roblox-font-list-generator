# Roblox Font List Generator

Automatically generate a list of all Roblox fonts, including local and cloud
fonts.

## Usage

You'll need to have [Rokit](https://github.com/rojo-rbx/rokit) installed.
This is a toolchain manager and will automatically install the required
tools for this project ([Lune](https://github.com/filiptibell/lune) and
[StyLua](https://github.com/johnnymorganz/stylua)).

Once you have Rokit installed, you can run the following command to install
the required tools:

```sh
rokit install
```

Then, you can run the following command to generate the font list:

```sh
lune run generate
```

The font list will be written to `build/FontList.luau` in the current directory, and comes with built-in type definitions. A `build/FontList.json` file will also be generated (minified, enums shortened to a string; see [the JSON preview](#json-preview) below).

## Commands

Every command takes `-v` for progress logging, or `-vv` to include debug detail.

### Authentication

Roblox has required authentication on the asset delivery endpoints since April
2025, and throttles unauthenticated traffic — which is what a CI runner looks
like from the outside. `generate` and `preview` both accept an optional
`--auth`:

| Form | Credential |
| --- | --- |
| *omitted* | Whatever the environment carries: `ROBLOX_OPEN_CLOUD_API_KEY`, then `ROBLOSECURITY`. Unauthenticated if neither is set. |
| `--auth` | A `.ROBLOSECURITY` cookie: `ROBLOSECURITY` from the environment if set, otherwise one from a Roblox installation on this machine. |
| `--auth <value>` | The given credential, sent as whichever kind it turns out to be. |

A value is classified by what it looks like rather than by where it came from, so
either kind works anywhere one is accepted. Cookies carry the warning text
Roblox embeds in them, or arrive already in `.ROBLOSECURITY=` form; anything
else is treated as an API key. A cookie put in `ROBLOX_OPEN_CLOUD_API_KEY` still
authenticates as a cookie rather than silently failing.

Credentials can also live in a `.env` file in the working directory — see
[`.env.example`](.env.example). Real environment variables take precedence, so
CI supplies the same names as secrets. Passing a credential as `--auth <value>`
works but puts it in process listings and usually in CI logs, so the command
warns when you do.

> [!CAUTION]
> A `.ROBLOSECURITY` cookie is full access to the account it belongs to, not a
> scoped credential. An Open Cloud API key can be scoped and revoked
> individually, so prefer one wherever it is sufficient.

Asset delivery is throttled hard enough that a credential is not always enough
on its own, so requests work down a ladder: the v2 endpoint with whatever
credential is configured, retried five times with backoff reaching a minute,
then the v1 endpoint with **no credential at all**, on the same ladder. Running
unauthenticated against v1 is how this generator worked for a long time, so it
is worth one genuinely different-looking attempt before giving up. Whichever
rung answers is reused for the rest of the run.

### `generate`

Builds the font list from the current Roblox Studio release and the cloud font
catalogue, writing `build/FontList.luau` and `build/FontList.json`.

```sh
lune run generate
```

| Argument | Default | Description |
| --- | --- | --- |
| `--ext <extension>` | `luau` | Extension for the generated Luau file. |

### `diff`

Compares two generated font lists and writes the additions and deletions to
`build/FontList.diff`. Either file may be the Luau flavour or the JSON one, in
either position, chosen by file extension. Entries are matched on `ContentUri`,
and each line ends with the uri it matched:

```diff
- Montserrat (rbxassetid://11702779517)

+ Builder Extended (rbxassetid://16658237174)
+ Zekton (rbxasset://fonts/families/Zekton.json)
```

```sh
lune run diff build/OldFontList.luau build/FontList.luau
```

Modifications to fonts that exist in both lists are not reported, only whole
entries appearing and disappearing.

### `preview`

Renders a sample of the given fonts to a pair of SVG files, one with black
text and one with white, so the right one can be shown for the reader's theme.

```sh
lune run preview -- --fonts "rbxasset://fonts/families/BuilderSans.json,rbxassetid://12187360881"
```

| Argument | Default | Description |
| --- | --- | --- |
| `--fonts <ids>` | *required* | Comma separated content uris, as they appear in the font list. |
| `--text <text>` | `The quick brown fox jumps over the lazy dog.` | Sample text. |
| `--width <pixels>` | `1024` | Maximum image width. The sample size shrinks to fit rather than the text being clipped. |
| `--output <dir>` | `temp/preview` | Where the pair is written. Files are named after a hash of the inputs. |
| `--registry <dir>` | `temp/downloads` | Where cloud font descriptors and downloads are kept. Runs `generate` first if it does not exist. |
| `--content <dir>` | Studio install | Overrides the Roblox Studio content directory that local fonts are read from. |
| `--resvg [path]` | off | Also write PNGs, using [resvg](https://github.com/linebender/resvg). On its own it uses whatever is on `PATH`; give it a path to use a binary that is not. |
| `--scale <factor>` | `2` | Multiplies the PNG dimensions, so a preview stays sharp when displayed at the SVG's nominal width. |

Fonts are laid out alphabetically by family name, regardless of the order they
are listed in. Every glyph is emitted as an outline path rather than as text,
because GitHub renders README images in a sandbox with no access to webfonts,
so a `<text>` element would silently fall back to a default face.

`--content` exists for machines with no Roblox Studio installation. Unpack the
Studio fonts package into a directory named `fonts` and point at its parent;
the workflow in this repository does exactly that to render previews on a
runner.

`--resvg` writes a matching pair of PNGs alongside the SVGs, for places that
will not render an SVG at all — GitHub release notes being the case this was
added for. resvg is not bundled; install it with `cargo install resvg`, or
grab a [prebuilt binary](https://github.com/linebender/resvg/releases) if one
exists for your platform. Labels are set in Arimo, taken from the same content
directory as the fonts themselves, so the output does not depend on which
fonts happen to be installed on the machine doing the rendering.

Embed the pair with a `<picture>` element so it follows the reader's theme:

```html
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="preview_white.svg">
  <img alt="Font preview" src="preview_black.svg">
</picture>
```

## Preview

Here's a preview of the generated font list:

```luau
--!strict
-- This file is automatically generated by Font List Generate
-- by @cxmeel (cxmeels). Do not edit this file manually.

export type IFont = {
    ContentUri: string,
    Name: string,
    PostScript: string,
    Aliases: { string },
    Weights: { Enum.FontWeight },
    Styles: { Enum.FontStyle },
}

local fonts: { IFont } = {
    -- Local fonts --
    {
        Name = "Accanthis ADF Std",
        PostScript = "accanthis_adf_std",
        Aliases = {},
        ContentUri = "rbxasset://fonts/families/AccanthisADFStd.json",
        Weights = { Enum.FontWeight.Regular },
        Styles = { Enum.FontStyle.Normal },
    },
    {
        Name = "Amatic SC",
        PostScript = "amatic_sc",
        Aliases = {},
        ContentUri = "rbxasset://fonts/families/AmaticSC.json",
        Weights = { Enum.FontWeight.Regular, Enum.FontWeight.Bold },
        Styles = { Enum.FontStyle.Normal },
    },
    {
        Name = "Arimo",
        PostScript = "arimo",
        Aliases = {},
        ContentUri = "rbxasset://fonts/families/Arimo.json",
        Weights = {
            Enum.FontWeight.Bold,
            Enum.FontWeight.Regular,
            Enum.FontWeight.Medium,
            Enum.FontWeight.SemiBold,
        },
        Styles = { Enum.FontStyle.Normal, Enum.FontStyle.Italic },
    },
    {
        Name = "Arimo (Legacy)",
        PostScript = "arimo_legacy",
        Aliases = {},
        ContentUri = "rbxasset://fonts/families/LegacyArimo.json",
        Weights = { Enum.FontWeight.Regular, Enum.FontWeight.Bold },
        Styles = { Enum.FontStyle.Normal },
    },
    {
        Name = "Arimo (Legacy)",
        PostScript = "arimo_legacy",
        Aliases = {},
        ContentUri = "rbxasset://fonts/families/LegacyArial.json",
        Weights = { Enum.FontWeight.Regular, Enum.FontWeight.Bold },
        Styles = { Enum.FontStyle.Normal },
    },
    {
        Name = "Balthazar",
        PostScript = "balthazar",
        Aliases = {},
        ContentUri = "rbxasset://fonts/families/Balthazar.json",
        Weights = { Enum.FontWeight.Regular },
        Styles = { Enum.FontStyle.Normal },
    },
    ...
    -- Cloud fonts --
    {
        Name = "Noto Sans",
        PostScript = "noto_sans",
        Aliases = {
            "Noto Color Emoji",
            "Noto Sans Symbols",
            "Noto Sans Symbols2",
        },
        ContentUri = "rbxassetid://12187370747",
        Weights = {
            Enum.FontWeight.Bold,
            Enum.FontWeight.SemiBold,
            Enum.FontWeight.ExtraLight,
            Enum.FontWeight.Thin,
            Enum.FontWeight.ExtraBold,
            Enum.FontWeight.Medium,
            Enum.FontWeight.Light,
            Enum.FontWeight.Regular,
            Enum.FontWeight.Heavy,
        },
        Styles = { Enum.FontStyle.Normal, Enum.FontStyle.Italic },
    },
    ...
}

return fonts
```

## JSON Preview

```json
[
    {
        "Aliases": {},
        "ContentUri": "rbxasset://fonts/families/AccanthisADFStd.json",
        "Name": "Accanthis ADF Std",
        "PostScript": "accanthis_adf_std",
        "Styles": [
            "Normal"
        ],
        "Weights": [
            "Regular"
        ]
    },
    {
        "Aliases": {},
        "ContentUri": "rbxasset://fonts/families/AmaticSC.json",
        "Name": "Amatic SC",
        "PostScript": "amatic_sc",
        "Styles": [
            "Normal"
        ],
        "Weights": [
            "Regular",
            "Bold"
        ]
    },
    ...,
    {
        "Aliases": [
            "Noto Color Emoji",
            "Noto Sans Symbols",
            "Noto Sans Symbols2"
        ],
        "ContentUri": "rbxassetid://12187370747",
        "Name": "Noto Sans",
        "PostScript": "noto_sans",
        "Styles": [
            "Normal",
            "Italic"
        ],
        "Weights": [
            "Bold",
            "SemiBold",
            "ExtraLight",
            "Thin",
            "ExtraBold",
            "Medium",
            "Light",
            "Regular",
            "Heavy"
        ]
    },
    ...
]
```

## Duplicate Entries

A handful of families are published twice: once as a local font shipped with
Roblox Studio, and once as a cloud asset. Both entries are listed, because both
are real things you can reference, and the pairs carry identical weight and
style coverage — the only difference is where the font comes from.

Prefer the local entry where you have the choice. It is already on the user's
machine and needs no additional content download.

`ContentUri` is the only field guaranteed to be unique. To keep lookups
unambiguous, the cloud copy of a duplicated family carries a `_cloud` suffix on
its `PostScript` name, leaving the bare name on the local one:

| Name | ContentUri | PostScript |
| --- | --- | --- |
| Builder Sans | `rbxasset://fonts/families/BuilderSans.json` | `builder_sans` |
| Builder Sans | `rbxassetid://16658221428` | `builder_sans_cloud` |

The exception is `Arimo (Legacy)`, which appears twice as a local font. Roblox
dropped Arial in favour of Arimo and renamed the family in place, so both
`LegacyArimo.json` and `LegacyArial.json` now declare the same name. Neither is
a cloud duplicate, and both are left as they are.
