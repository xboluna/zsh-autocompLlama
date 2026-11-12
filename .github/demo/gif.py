"""Encode the frames written by render.js into the README's GIF.

    python3 gif.py <frames dir> <out.gif> [fps]

960x600, with one palette for the whole animation so that frames differ
only where the picture does. Needs Pillow and numpy.
"""
import glob
import sys

import numpy as np
from PIL import Image

SIZE = (960, 600)
# A pixel with a channel above this is text or an accent, not background.
BRIGHT = 96


def load(path: str) -> Image.Image:
    return Image.open(path).convert("RGB").resize(SIZE, Image.LANCZOS)


def median_cut(pixels: np.ndarray, colors: int) -> list[int]:
    width = 1024
    height = len(pixels) // width
    strip = Image.fromarray(pixels[: width * height].reshape(height, width, 3), "RGB")
    return strip.quantize(colors=colors, method=Image.Quantize.MEDIANCUT).getpalette()[: colors * 3]


def build_palette(paths: list[str]) -> Image.Image:
    """Half the palette for the dark gradients, half for text and accents.

    Nearly every pixel is dark background, so a palette cut from whole
    frames spends itself on the gradients and washes the colours out of the
    text; one that covers the colours bands the gradients. Cut separately,
    both come out right.
    """
    sample = [load(p) for p in paths[:: max(1, len(paths) // 24)]]
    pixels = np.concatenate([np.array(frame).reshape(-1, 3) for frame in sample])
    bright = pixels.max(axis=1) > BRIGHT
    palette = median_cut(pixels[~bright], 128) + median_cut(pixels[bright], 127)
    holder = Image.new("P", (1, 1))
    holder.putpalette(palette + [0] * (768 - len(palette)))
    return holder


def main() -> None:
    frames_dir, out = sys.argv[1], sys.argv[2]
    fps = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    paths = sorted(glob.glob(f"{frames_dir}/f*.png"))
    palette = build_palette(paths)
    # No dithering: its noise would differ from frame to frame.
    frames = [load(p).quantize(palette=palette, dither=Image.Dither.NONE) for p in paths]
    # GIF delays are in hundredths of a second: spread the rounding so the
    # animation keeps its length.
    delays: list[int] = []
    due = 0.0
    for _ in frames:
        due += 1000 / fps
        delays.append(round((due - sum(delays)) / 10) * 10)
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=delays, loop=0, disposal=1)
    print(f"{out}: {len(frames)} frames, {sum(delays) / 1000:.1f}s")


if __name__ == "__main__":
    main()
