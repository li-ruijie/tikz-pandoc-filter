# tikz-pandoc-filter

A Pandoc Lua filter that converts TikZ diagrams to PNG and SVG images.

## Features

- Processes TikZ environments from Markdown to images
- Generates both PNG and SVG output formats
- Smart caching based on source file modification time
- Cross-platform support (Windows and Unix)
- Configurable output options (alignment, caption position, image format)
- Embedded PDF cropping (no external pdfcrop dependency)
- Automatic Ghostscript detection (including Windows Registry lookup)

## Requirements

- Pandoc 2.0+
- LuaLaTeX
- Ghostscript
- ImageMagick (for PNG output)
- dvisvgm (for SVG output)

## Installation

Copy `tikz.lua` to your project or Pandoc filters directory.

## Usage

### Basic Usage

```bash
pandoc input.md -o output.html --lua-filter tikz.lua
pandoc input.md -o output.docx --lua-filter tikz.lua
```

### Syntax Options

#### 1. Raw LaTeX Block

````markdown
```{=latex}
\begin{tikzpicture}
  \draw (0,0) -- (1,1);
\end{tikzpicture}
```
````

#### 2. Code Block with `.tikz` Class (supports attributes)

````markdown
```{.tikz width=80% caption="My diagram" label="fig:diagram"}
\begin{tikzpicture}
  \draw (0,0) circle (1);
\end{tikzpicture}
```
````

### Attributes

| Attribute | Description |
|-----------|-------------|
| `caption` | Caption text displayed with the figure |
| `label` | HTML id / reference label for the figure |
| `width` | Image width (e.g., `80%`, `400px`) |
| `height` | Image height |

## Configuration

Edit the configuration section at the top of `tikz.lua`:

```lua
local TIKZ_IMAGES_DIR = "tikz-images"     -- Output directory
local FIGURE_ALIGNMENT = "center"          -- "center", "left", or "right"
local CAPTION_POSITION = "above"           -- "above" or "below"
local CAPTION_FIGURE_GAP = "1em"           -- Spacing between caption and figure
local OUTPUT_FORMATS = "png,svg"           -- "png", "svg", or "png,svg"
local HTML_FORMAT = "svg"                  -- Format for HTML output
local DOCX_FORMAT = "svg"                  -- Format for DOCX output
local DOCX_FIGURE_STYLE = "Figure"         -- Word style for figures
```

## Output Files

Generated images are saved in the `tikz-images/` directory:

```
tikz-images/
├── fig01-my-diagram.png
├── fig01-my-diagram.svg
├── fig02-another-figure.png
└── fig02-another-figure.svg
```

Filenames are generated from:
- Sequential figure number (01, 02, ...)
- Sanitized caption text (truncated to 32 characters)

## Caching

The filter uses smart caching to avoid regenerating images unnecessarily:

1. Compares image modification time with source Markdown file
2. Only regenerates when source file has been modified
3. After generation, syncs image mtime to source mtime

To force regeneration, delete the `tikz-images/` directory or touch the source file.

## TikZ Libraries

The filter pre-loads common TikZ libraries:
- `trees`
- `positioning`
- `arrows.meta`
- `shadows`

To add more libraries, modify the `tikz2image` function in `tikz.lua`.

## Example

Input (`example.md`):

````markdown
# My Document

Here's a simple diagram:

```{.tikz caption="A simple tree" width=60%}
\begin{tikzpicture}[
  every node/.style={draw, circle},
  level distance=1.5cm
]
\node {Root}
  child {node {A}}
  child {node {B}
    child {node {C}}
    child {node {D}}
  };
\end{tikzpicture}
```
````

Convert:

```bash
pandoc example.md -o example.html --lua-filter tikz.lua
```

## Credits

- Author: Li Ruijie
- Embedded pdfcrop based on [pdfcrop](https://ctan.org/pkg/pdfcrop) by Heiko Oberdiek

## License

MIT License. See [LICENSE](LICENSE) for details.
