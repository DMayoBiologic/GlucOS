# Regenerates the app icon PNGs: python3 scripts/make_app_icon.py Sources/App/Assets.xcassets/AppIcon.appiconset
# iPhone (full-bleed square; iOS rounds it): python3 scripts/make_app_icon.py Sources/iOS/Assets.xcassets/AppIcon.appiconset --ios
# Needs Pillow. Big Sur grid: 824 pt rounded body on a 1024 canvas, white drop with a CGM trace.
import math, os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4096  # supersampled canvas; 1024 pt grid * 4
k = S / 1024
out_dir = sys.argv[1]
IOS = "--ios" in sys.argv[2:]

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# Big Sur grid: 824x824 body centred on a 1024 canvas, ~185 corner radius.
body = (100*k, 100*k, 924*k, 924*k)
radius = 0 if IOS else 185*k

# Background gradient (top-left teal → bottom-right deep blue).
top, bot = (34, 197, 170), (24, 78, 168)
grad = Image.new("RGB", (S, S))
gd = ImageDraw.Draw(grad)
for y in range(S):
    gd.line([(0, y), (S, y)], fill=lerp(top, bot, y / S))

mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle(body, radius=radius, fill=255)

icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Soft drop shadow under the body.
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((body[0], body[1] + 12*k, body[2], body[3] + 12*k), radius=radius, fill=(0, 0, 0, 90))
shadow = shadow.filter(ImageFilter.GaussianBlur(14*k))
if not IOS:
    icon.alpha_composite(shadow)

bg = grad.convert("RGBA"); bg.putalpha(mask)
icon.alpha_composite(bg)

# Subtle top highlight.
hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
hd = ImageDraw.Draw(hl)
for i in range(int(330*k)):
    a = int(38 * (1 - i / (330*k)))
    hd.line([(0, body[1] + i), (S, body[1] + i)], fill=(255, 255, 255, a))
hm = Image.new("L", (S, S), 0); hm.paste(mask, (0, 0))
hl.putalpha(Image.composite(hl.getchannel("A"), Image.new("L", (S, S), 0), hm))
icon.alpha_composite(hl)

# Drop: circle + tangent lines to an apex.
cx, cy, r = 512*k, 580*k, 215*k
apex = (cx, 205*k)
d = cy - apex[1]
phi = math.acos(r / d)
def pt(angle): return (cx + r * math.cos(angle), cy + r * math.sin(angle))
t1, t2 = pt(-math.pi/2 - phi), pt(-math.pi/2 + phi)

def drop_layer(fill, dx=0, dy=0):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    dd = ImageDraw.Draw(layer)
    dd.ellipse((cx - r + dx, cy - r + dy, cx + r + dx, cy + r + dy), fill=fill)
    dd.polygon([(apex[0] + dx, apex[1] + dy), (t1[0] + dx, t1[1] + dy), (t2[0] + dx, t2[1] + dy)], fill=fill)
    return layer

ds = drop_layer((0, 40, 90, 110), 0, 18*k).filter(ImageFilter.GaussianBlur(18*k))
icon.alpha_composite(ds)
drop = drop_layer((255, 255, 255, 255))
icon.alpha_composite(drop)

# CGM trace across the drop, clipped to it, with the in-range band.
trace = Image.new("RGBA", (S, S), (0, 0, 0, 0))
td = ImageDraw.Draw(trace)
td.rectangle((0, 540*k, S, 650*k), fill=(34, 197, 94, 55))
pts = []
x0, x1 = cx - r - 20*k, cx + r + 20*k
n = 200
for i in range(n + 1):
    x = x0 + (x1 - x0) * i / n
    t = i / n
    y = 595*k - 62*k * math.sin(t * math.pi * 2.0 + 0.9)
    pts.append((x, y))
# Round-capped stroke: stamp discs along a dense polyline so the edge stays smooth.
w = 16*k
for (ax, ay), (bx, by) in zip(pts, pts[1:]):
    for j in range(8):
        u = j / 8
        px_, py_ = ax + (bx - ax) * u, ay + (by - ay) * u
        td.ellipse((px_ - w, py_ - w, px_ + w, py_ + w), fill=(24, 96, 190, 255))
# current-reading dot
ex, ey = cx + 95*k, None
best = min(pts, key=lambda p: abs(p[0] - ex))
td.ellipse((best[0] - 34*k, best[1] - 34*k, best[0] + 34*k, best[1] + 34*k), fill=(24, 96, 190, 255))
td.ellipse((best[0] - 16*k, best[1] - 16*k, best[0] + 16*k, best[1] + 16*k), fill=(255, 255, 255, 255))
trace.putalpha(Image.composite(trace.getchannel("A"), Image.new("L", (S, S), 0), drop.getchannel("A")))
icon.alpha_composite(trace)

os.makedirs(out_dir, exist_ok=True)
if IOS:
    # The body, edge to edge: iOS applies its own mask.
    full = icon.crop(tuple(int(v) for v in body)).convert("RGB").resize((1024, 1024), Image.LANCZOS)
    full.save(os.path.join(out_dir, "AppIcon-1024.png"))
    print("ok")
    sys.exit(0)
for px in (16, 32, 64, 128, 256, 512, 1024):
    icon.resize((px, px), Image.LANCZOS).save(os.path.join(out_dir, f"icon_{px}.png"))
print("ok")
