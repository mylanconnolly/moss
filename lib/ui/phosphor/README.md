# Phosphor Regular subset

Unmodified source SVGs from [phosphor-icons/core](https://github.com/phosphor-icons/core),
revision `2b75f3ad12b420c9504ef05df8d2564a28f8500e`, directory `raw/regular/`.
Copyright Phosphor Icons; MIT license in [LICENSE](LICENSE). The same license
is included in the boot archive at `assets/licenses/phosphor.txt`.

Moss keeps its semantic names (`settings`, `refresh`, etc.) and also accepts
the upstream names. `lib/ui/icons.zig` records the mapping. The regular weight
uses rounded 16-unit strokes on a 256-unit viewBox.

`lib/ui/iconpath.zig` compiles these SVGs into line segments during the normal
Zig build. Circular arcs and cubic curves are flattened to 0.125 source-unit
tolerance (less than 0.1 pixel at a 192px output size). There is no runtime SVG
parser, network fetch, external converter, or additional asset service.
The decoder deliberately supports only the geometry this pinned subset uses;
unsupported elements/commands fail at compile time. To update an icon, replace
its source from a pinned upstream revision, update this provenance, and run
`zig build test` and the GUI gate, including visual inspection at 1x/1.5x/3x.
