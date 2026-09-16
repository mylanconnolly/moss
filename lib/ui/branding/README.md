# Moss mark

[`moss.svg`](moss.svg) is the canonical, original Moss brand mark: a rounded
lowercase **m** with a leaf growing above it. The two low arches suggest the
cushion-like growth of moss; the leaf keeps the small monochrome silhouette
recognizable without a wordmark. It was created for this project and is not a
Phosphor icon or a modification of one. It is distributed under the project's
license.

Use this mark for Moss itself, including the desktop's system menu. Keep the
accessible name **Moss** when the icon replaces visible text. Application and
document actions should continue to use the regular symbolic icon catalog.

The SVG uses a transparent 256 × 256 view box, `currentColor`, and rounded
16-unit strokes. Preserve its square aspect ratio and clear space; do not
stretch it or crop to the ink. The desktop renders it in the current theme's
foreground color at the same scale as its other icons (20 pixels at the
default 16-pixel UI text size). A single foreground color makes it suitable
for light, dark, and high-contrast themes. The SVG can also be used directly
in project documentation and other branding materials.

Native callers use `shared.gui.icons.Icon.moss`, or parse the name `"moss"` with
`shared.gui.icons.parse`. Both the GUI and exported SVG use this one asset; there
is no separately maintained bitmap or path copy.
