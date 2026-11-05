#!/usr/bin/env python3
"""
Render screenshot-sysmixer.png via headless Chromium so it matches MOD-UI's
actual rendering of the pedal (real fonts, real knob sprite, real CSS
gradients). Ported from the sitar repo's render_screenshot.py.

Pipeline: resolve the Mustache tokens MOD-UI fills at runtime, point the knob
sprite URL at a local file, drop the audio/MIDI/CV port loops (the jacks sit
outside the frame and are cropped away), then screenshot at WIDTH x HEIGHT.

When you fork this template, update the plugin-specific constants below
(ICON/STYLE/SPRITE/OUT names, the SUBSTITUTIONS to match modgui.ttl, and
WIDTH/HEIGHT to your pedal size).

Run inside any Python env that has Playwright + Chromium:
    pip install playwright && playwright install chromium
    python3 render_screenshot.py
"""

import os
import re
import shutil
import tempfile

from playwright.sync_api import sync_playwright

HERE   = os.path.dirname(os.path.abspath(__file__))
ICON   = os.path.join(HERE, "icon-sysmixer.html")
STYLE  = os.path.join(HERE, "stylesheet-sysmixer.css")
SPRITE = os.path.join(HERE, "knobs", "black.png")
OUT    = os.path.join(HERE, "screenshot-sysmixer.png")

# The pedal as it looks with three plugins sent to it: header, three rows
# (the script hides unused ones), master. 40 + 3 * 72 + 62 px tall.
WIDTH  = 300
HEIGHT = 318
EXAMPLE_CHANNELS = {1: ("Guitar", "MO"), 2: ("Reverb", "ST"), 3: ("Looper", "ST")}
# Device pixel ratio for the render. 2x keeps the same CSS layout but outputs
# at double resolution — crisper on HiDPI screens and in the printed manual.
SCALE  = 2

# Same values you put in modgui.ttl.
SUBSTITUTIONS = {
    "{{brand}}":   "Stefan",
    "{{label}}":   "System Mixer",
    "{{color}}":   "wood3",
    "{{knob}}":    "gold",
    "{{{cns}}}":   "",   # cache-bust class suffix; harmless to drop
    "{{{ns}}}":    "",   # cache-bust query string; not needed for local files
    "{{instancename}}": "sysmixer-render",
}


def render_template(html: str) -> str:
    # Drop HTML comments first: a doc comment may mention Mustache tokens (e.g.
    # the icon's "{{#effect.ports.audio.input}}" example), which the port-loop
    # regex below would otherwise match across, deleting real markup.
    html = re.sub(r"<!--.*?-->", "", html, flags=re.DOTALL)
    for k, v in SUBSTITUTIONS.items():
        html = html.replace(k, v)
    # Drop the audio/midi/cv port iteration blocks. The jacks are positioned
    # outside the pedal frame and cropped by overflow:hidden, so the screenshot
    # doesn't need them (and their Mustache loops can't render statically).
    for kind in ("audio", "midi", "cv"):
        for direction in ("input", "output"):
            html = re.sub(
                r"\{\{#effect\.ports\." + kind + r"\." + direction + r"\}\}.*?\{\{/effect\.ports\." + kind + r"\." + direction + r"\}\}",
                "", html, flags=re.DOTALL,
            )
    # The knob value labels are filled by the modgui JS at runtime; show
    # the defaults statically so the screenshot isn't missing them.
    html = re.sub(r'(<span class="mx-val" mx-symbol="pan\d">)', r"\1C", html)
    html = re.sub(r'(<span class="mx-val" mx-symbol="(?:gain\d|master)">)', r"\g<1>0.0", html)
    return html


def render_stylesheet(css: str, sprite_url: str) -> str:
    for k, v in SUBSTITUTIONS.items():
        css = css.replace(k, v)
    css = css.replace("/resources/knobs/black.png", sprite_url)
    return css


def main():
    with open(ICON,  "r", encoding="utf-8") as f: icon_html = f.read()
    with open(STYLE, "r", encoding="utf-8") as f: css       = f.read()

    sprite_url = "file://" + SPRITE
    css        = render_stylesheet(css, sprite_url)
    pedal_html = render_template(icon_html)
    for ch, (name, mode) in EXAMPLE_CHANNELS.items():
        pedal_html = pedal_html.replace(f'<div class="mx-row" mx-channel="{ch}">',
                                        f'<div class="mx-row mx-used" mx-channel="{ch}">')
        pedal_html = pedal_html.replace(
            f'<span class="mx-num">{ch}</span><span class="mx-name"></span><span class="mx-mode"></span>',
            f'<span class="mx-num">{ch}</span><span class="mx-name">{name}</span>'
            f'<span class="mx-mode{" stereo" if mode == "ST" else ""}">{mode}</span>')

    page = f"""<!doctype html>
<html><head>
<meta charset="utf-8">
<style>
  html, body {{
    margin: 0; padding: 0;
    width: {WIDTH}px; height: {HEIGHT}px;
    overflow: hidden;
    background: transparent;
  }}
  .pedal-host {{ position: relative; width: {WIDTH}px; height: {HEIGHT}px; }}
{css}
</style></head>
<body><div class="pedal-host">{pedal_html}</div></body></html>"""

    with tempfile.TemporaryDirectory(prefix="sysmixer-render-") as tmp:
        page_path = os.path.join(tmp, "render.html")
        with open(page_path, "w", encoding="utf-8") as f:
            f.write(page)

        with sync_playwright() as p:
            browser = p.chromium.launch()
            context = browser.new_context(
                viewport={"width": WIDTH, "height": HEIGHT},
                device_scale_factor=SCALE,
            )
            tab = context.new_page()
            tab.goto("file://" + page_path)
            tab.wait_for_load_state("networkidle")

            tmp_out = os.path.join(tmp, "screenshot.png")
            tab.screenshot(path=tmp_out, omit_background=False, full_page=False)
            browser.close()

        shutil.copyfile(tmp_out, OUT)
        print(f"Wrote {OUT} ({WIDTH*SCALE}x{HEIGHT*SCALE} @ {SCALE}x, rendered by headless Chromium)")


if __name__ == "__main__":
    main()
