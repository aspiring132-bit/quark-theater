#!/usr/bin/env python3
"""Generate all brand assets, tvOS App Icon imagestack layers, Top Shelf banner, and in-app logos.
Uses pure PIL (Pillow).
"""
import os
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageOps, ImageFont

ROOT = Path(__file__).resolve().parents[1]
ASSETS_DIR = ROOT / "QuarkTheater" / "Assets.xcassets"
BRAND_DIR = ASSETS_DIR / "App Icon & Top Shelf Image.brandassets"

MASTER_IMAGE_PATH = "/Users/wangbin/.gemini/antigravity/brain/bea6057a-9c9c-48b7-9c0b-dde8249221da/quark_theater_app_icon_1792246778683.jpg"

def main():
    if not os.path.exists(MASTER_IMAGE_PATH):
        print(f"Error: Master image not found at {MASTER_IMAGE_PATH}")
        sys.exit(1)

    print(f"Loading master artwork: {MASTER_IMAGE_PATH}")
    master = Image.open(MASTER_IMAGE_PATH).convert("RGBA")
    w_master, h_master = master.size

    # =========================================================================
    # Step 1: Extract Isolated Q Emblem (Transparent Background)
    # =========================================================================
    print("Extracting sharp isolated metallic Q emblem...")
    cx, cy = 508, 498
    r_circle = 275

    scale = 4
    roi = Image.new("L", (w_master * scale, h_master * scale), 0)
    draw_roi = ImageDraw.Draw(roi)
    draw_roi.ellipse([(cx - r_circle) * scale, (cy - r_circle) * scale,
                      (cx + r_circle) * scale, (cy + r_circle) * scale], fill=255)
    tail_points = [
        ((cx + 100) * scale, (cy + 100) * scale),
        ((cx + 310) * scale, (cy + 220) * scale),
        ((cx + 315) * scale, (cy + 300) * scale),
        ((cx + 180) * scale, (cy + 310) * scale),
        ((cx + 80) * scale, (cy + 240) * scale),
    ]
    draw_roi.polygon(tail_points, fill=255)
    draw_roi.ellipse([((cx + 160) * scale, (cy + 170) * scale),
                      ((cx + 325) * scale, (cy + 310) * scale)], fill=255)
    roi = roi.filter(ImageFilter.GaussianBlur(radius=6 * scale))
    roi = roi.resize((w_master, h_master), Image.Resampling.LANCZOS)

    gray = master.convert("L")
    def ramp(p):
        if p < 16:
            return 0
        elif p < 45:
            return int(((p - 16) / 29.0) * 255)
        else:
            return 255

    lum_alpha = gray.point(ramp)
    final_alpha = Image.new("L", (w_master, h_master), 0)
    for y in range(h_master):
        for x in range(w_master):
            m = roi.getpixel((x, y))
            if m > 0:
                la = lum_alpha.getpixel((x, y))
                final_alpha.putpixel((x, y), int(la * (m / 255.0)))

    isolated_emblem = master.copy()
    isolated_emblem.putalpha(final_alpha)
    ebbox = isolated_emblem.getbbox()
    emblem_tight = isolated_emblem.crop(ebbox)
    print(f"Emblem isolated successfully. Tight bbox: {ebbox}, size: {emblem_tight.size}")

    # =========================================================================
    # Step 2: Generate In-App Logo (`AppLogo.imageset`)
    # =========================================================================
    print("Generating In-App Logo (AppLogo.imageset)...")
    applogo_dir = ASSETS_DIR / "AppLogo.imageset"
    applogo_dir.mkdir(parents=True, exist_ok=True)

    # Crop squircle tile from master
    squircle_crop = master.crop((118, 118, 906, 906)) # 788x788
    # High-res anti-aliased squircle mask
    logo_512 = squircle_crop.resize((512, 512), Image.Resampling.LANCZOS)
    s_scale = 4
    mask_512 = Image.new("L", (512 * s_scale, 512 * s_scale), 0)
    draw_m512 = ImageDraw.Draw(mask_512)
    pad = 8 * s_scale
    draw_m512.rounded_rectangle((pad, pad, 512 * s_scale - pad, 512 * s_scale - pad),
                                radius=112 * s_scale, fill=255)
    mask_512 = mask_512.resize((512, 512), Image.Resampling.LANCZOS)
    logo_512.putalpha(mask_512)
    logo_256 = logo_512.resize((256, 256), Image.Resampling.LANCZOS)

    logo_512.save(applogo_dir / "2x.png", format="PNG")
    logo_256.save(applogo_dir / "1x.png", format="PNG")

    contents_json_applogo = """{
  "images" : [
    {
      "filename" : "1x.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
    (applogo_dir / "Contents.json").write_text(contents_json_applogo, encoding="utf-8")
    print(f"AppLogo saved to {applogo_dir}")

    # =========================================================================
    # Step 3: Generate tvOS Parallax App Icon (Back, Middle, Front)
    # =========================================================================
    print("Generating tvOS Parallax App Icon imagestack...")
    app_icon_dir = BRAND_DIR / "App Icon.imagestack"

    w_canvas_2x, h_canvas_2x = 800, 480
    w_canvas_1x, h_canvas_1x = 400, 240

    # --- A. Back Layer (Opaque RGB) ---
    crop_h = int(1024 / (800 / 480))
    y0 = (1024 - crop_h) // 2
    back_base = master.convert("RGB").crop((0, y0, 1024, y0 + crop_h)).resize((w_canvas_2x, h_canvas_2x), Image.Resampling.LANCZOS)

    # Ambient screen glow in center
    screen_patch = Image.new("RGB", (w_canvas_2x, h_canvas_2x), (12, 22, 34))
    draw_sp = ImageDraw.Draw(screen_patch)
    draw_sp.rounded_rectangle([120, 40, 680, 400], radius=16, fill=(18, 36, 52))
    for y in range(40, 400):
        factor = (y - 40) / 360.0
        r = int(24 * (1 - factor) + 8 * factor)
        g = int(48 * (1 - factor) + 16 * factor)
        b = int(72 * (1 - factor) + 26 * factor)
        draw_sp.line([(120, y), (680, y)], fill=(r, g, b))
    screen_patch = screen_patch.filter(ImageFilter.GaussianBlur(radius=30))

    center_mask = Image.new("L", (w_canvas_2x, h_canvas_2x), 0)
    draw_cm = ImageDraw.Draw(center_mask)
    draw_cm.ellipse([140, 30, 660, 450], fill=255)
    center_mask = center_mask.filter(ImageFilter.GaussianBlur(radius=40))

    back_2x = Image.composite(screen_patch, back_base, center_mask)
    back_1x = back_2x.resize((w_canvas_1x, h_canvas_1x), Image.Resampling.LANCZOS)

    back_dir = app_icon_dir / "Back.imagestacklayer" / "Content.imageset"
    back_dir.mkdir(parents=True, exist_ok=True)
    back_2x.save(back_dir / "2x.png", format="PNG")
    back_1x.save(back_dir / "1x.png", format="PNG")
    print("Back layer saved (RGB).")

    # --- B. Middle Layer (Neon glow / halo, RGBA) ---
    middle_2x = Image.new("RGBA", (w_canvas_2x, h_canvas_2x), (0, 0, 0, 0))
    draw_mid = ImageDraw.Draw(middle_2x)
    glow_aura = Image.new("RGBA", (w_canvas_2x, h_canvas_2x), (0, 0, 0, 0))
    draw_aura = ImageDraw.Draw(glow_aura)
    draw_aura.ellipse([400 - 160, 240 - 160, 400 + 160, 240 + 160], fill=(0, 245, 255, 140))
    draw_aura.ellipse([400 - 190, 240 - 190, 400 + 190, 240 + 190], fill=(138, 43, 226, 75))
    glow_aura = glow_aura.filter(ImageFilter.GaussianBlur(radius=45))
    middle_2x = Image.alpha_composite(middle_2x, glow_aura)
    middle_1x = middle_2x.resize((w_canvas_1x, h_canvas_1x), Image.Resampling.LANCZOS)

    mid_dir = app_icon_dir / "Middle.imagestacklayer" / "Content.imageset"
    mid_dir.mkdir(parents=True, exist_ok=True)
    middle_2x.save(mid_dir / "2x.png", format="PNG")
    middle_1x.save(mid_dir / "1x.png", format="PNG")
    print("Middle layer saved (RGBA).")

    # --- C. Front Layer (Floating metallic Q emblem, RGBA) ---
    target_h_2x = 390
    target_w_2x = int(emblem_tight.width * (target_h_2x / emblem_tight.height))
    emblem_scaled_2x = emblem_tight.resize((target_w_2x, target_h_2x), Image.Resampling.LANCZOS)

    front_2x = Image.new("RGBA", (w_canvas_2x, h_canvas_2x), (0, 0, 0, 0))
    paste_x = (w_canvas_2x - target_w_2x) // 2
    paste_y = (h_canvas_2x - target_h_2x) // 2
    front_2x.paste(emblem_scaled_2x, (paste_x, paste_y), emblem_scaled_2x)
    front_1x = front_2x.resize((w_canvas_1x, h_canvas_1x), Image.Resampling.LANCZOS)

    front_dir = app_icon_dir / "Front.imagestacklayer" / "Content.imageset"
    front_dir.mkdir(parents=True, exist_ok=True)
    front_2x.save(front_dir / "2x.png", format="PNG")
    front_1x.save(front_dir / "1x.png", format="PNG")
    print("Front layer saved (RGBA).")

    # =========================================================================
    # Step 4: Generate Top Shelf Banner (1920x720, 3840x1440)
    # =========================================================================
    print("Generating Top Shelf Image banner...")
    w_top_2x, h_top_2x = 3840, 1440
    w_top_1x, h_top_1x = 1920, 720

    top_shelf_2x = Image.new("RGB", (w_top_2x, h_top_2x), (4, 7, 12))
    light_layer = Image.new("RGB", (w_top_2x, h_top_2x), (4, 7, 12))
    draw_ll = ImageDraw.Draw(light_layer)
    draw_ll.ellipse([200, 80, 2000, 1360], fill=(0, 140, 200))
    draw_ll.ellipse([1400, 200, 3600, 1300], fill=(10, 45, 80))
    draw_ll.ellipse([500, -200, 1800, 500], fill=(0, 220, 255))
    light_layer = light_layer.filter(ImageFilter.GaussianBlur(radius=150))
    top_shelf_2x = Image.blend(top_shelf_2x, light_layer, 0.45)

    # Scale emblem for top shelf: height = 920 px
    eh = 920
    ew = int(emblem_tight.width * (eh / emblem_tight.height))
    emblem_shelf = emblem_tight.resize((ew, eh), Image.Resampling.LANCZOS)
    em_x = 450
    em_y = (h_top_2x - eh) // 2
    top_shelf_2x.paste(emblem_shelf, (em_x, em_y), emblem_shelf)

    # Typography
    text_x = em_x + ew + 180
    title_y = h_top_2x // 2 - 200

    font_title = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 175)
    font_sub = ImageFont.truetype("/System/Library/Fonts/STHeiti Medium.ttc", 72)
    font_badge = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", 44)

    draw_ts = ImageDraw.Draw(top_shelf_2x)
    draw_ts.text((text_x + 2, title_y + 2), "QUARK THEATER", font=font_title, fill=(0, 180, 220))
    draw_ts.text((text_x, title_y), "QUARK THEATER", font=font_title, fill=(245, 250, 255))
    draw_ts.text((text_x + 5, title_y + 230), "电视上的私人影院 · 4K 原画直出", font=font_sub, fill=(160, 195, 220))

    badges = ["4K ULTRA HD", "DIRECT STREAM", "TMDB SCRAPER"]
    badge_x = text_x + 5
    badge_y = title_y + 360

    for b in badges:
        bbox = font_badge.getbbox(b)
        bw = bbox[2] - bbox[0] + 48
        bh = bbox[3] - bbox[1] + 28
        draw_ts.rounded_rectangle([badge_x, badge_y, badge_x + bw, badge_y + bh], radius=16,
                                  fill=(15, 30, 48), outline=(0, 190, 240), width=3)
        draw_ts.text((badge_x + 24, badge_y + 12), b, font=font_badge, fill=(0, 230, 255))
        badge_x += bw + 32

    top_shelf_1x = top_shelf_2x.resize((w_top_1x, h_top_1x), Image.Resampling.LANCZOS)

    top_shelf_dir = BRAND_DIR / "Top Shelf Image.imageset"
    top_shelf_dir.mkdir(parents=True, exist_ok=True)
    top_shelf_2x.save(top_shelf_dir / "2x.png", format="PNG")
    top_shelf_1x.save(top_shelf_dir / "1x.png", format="PNG")
    print(f"Top Shelf saved to {top_shelf_dir}")

    print("\nSUCCESS! All brand assets generated successfully.")

if __name__ == "__main__":
    main()
