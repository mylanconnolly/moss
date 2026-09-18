#!/bin/sh
# The image decoders' corpus: small pictures in every PNG colour type and
# depth (interlaced too), JPEG baseline and progressive at each sampling,
# GIF with a palette, interlace and transparency — each beside the RGBA
# bytes ImageMagick decodes it to, which the host tests compare against
# (JPEG within a small tolerance, since two IDCTs differ). Regenerate with
# ImageMagick 7: `sh tools/mkimages.sh`. Sizes are odd on purpose.
set -e
cd "$(dirname "$0")/testdata/images"
rm -f *.png *.jpg *.gif *.rgba *.txt
M=magick
# The source: a 23x17 picture with colour, edges and an alpha ramp.
$M -size 23x17 gradient:'#ff8800-#0044ff' \( -size 23x17 plasma:fractal -blur 0x1 \) -compose blend -define compose:args=50 -composite src.png
$M src.png \( -size 23x17 gradient:white-black \) -alpha off -compose copy_opacity -composite srca.png
for t in 0 2 3 4 6; do
  for d in 8 16; do
    case $t in
      0) $M src.png -colorspace gray -alpha off -define png:color-type=0 -depth $d gray$d.png ;;
      2) $M src.png -alpha off -define png:color-type=2 -depth $d rgb$d.png ;;
      3) [ $d = 8 ] && $M src.png -alpha off -colors 64 -define png:color-type=3 -depth 8 pal8.png ;;
      4) $M srca.png -colorspace gray -define png:color-type=4 -depth $d graya$d.png ;;
      6) $M srca.png -define png:color-type=6 -depth $d rgba$d.png ;;
    esac
  done
done
$M src.png -colorspace gray -alpha off -define png:color-type=0 -depth 1 gray1.png
$M src.png -colorspace gray -alpha off -define png:color-type=0 -depth 2 gray2.png
$M src.png -colorspace gray -alpha off -define png:color-type=0 -depth 4 gray4.png
$M src.png -alpha off -colors 4 -define png:color-type=3 -depth 2 pal2.png
$M src.png -alpha off -colors 16 -define png:color-type=3 -depth 4 pal4.png
$M srca.png -alpha off -colors 16 -define png:color-type=3 -depth 4 pal4.png
$M src.png -alpha off -interlace PNG -define png:color-type=2 -depth 8 rgb8i.png
$M srca.png -interlace PNG -define png:color-type=6 -depth 8 rgba8i.png
$M src.png -colorspace gray -alpha off -interlace PNG -depth 4 gray4i.png
# PNG with a tRNS chunk on a palette (a transparent colour).
$M srca.png -colors 32 -define png:color-type=3 pal8a.png
# JPEG.
$M src.png -alpha off -quality 92 -sampling-factor 4:4:4 base444.jpg
$M src.png -alpha off -quality 85 -sampling-factor 4:2:0 base420.jpg
$M src.png -alpha off -quality 80 -sampling-factor 4:2:2 base422.jpg
$M src.png -alpha off -colorspace gray -quality 90 gray.jpg
$M src.png -alpha off -quality 90 -interlace JPEG -sampling-factor 4:2:0 prog420.jpg
$M src.png -alpha off -quality 90 -interlace JPEG -sampling-factor 4:4:4 prog444.jpg
$M -size 80x60 plasma:fractal -alpha off -quality 75 -define jpeg:restart-interval=4 restart.jpg 2>/dev/null || $M -size 80x60 plasma:fractal -alpha off -quality 75 restart.jpg
# GIF.
$M src.png -alpha off -colors 32 pal.gif
$M src.png -alpha off -colors 16 -interlace GIF pali.gif
$M srca.png -colors 32 -transparent-color none trans.gif
$M src.png -alpha off -colors 256 pal256.gif
rm -f src.png srca.png
for f in *.png *.jpg *.gif; do
  $M "$f" -depth 8 "rgba:${f%.*}.rgba"
  identify -format "%w %h\n" "$f" > "${f%.*}.txt"
done
ls | wc -l
