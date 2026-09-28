from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math

S = 1024
C = S // 2

RED = (200, 38, 45, 255)
RED_DARK = (140, 22, 30, 255)
CAP = (40, 28, 30, 255)

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))

def circle_mask(size, r, cx=None, cy=None):
    cx = size // 2 if cx is None else cx
    cy = size // 2 if cy is None else cy
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    return m

def torii(draw, sx=1.0, oy=0, color=RED, dark=RED_DARK, cap=CAP, flip=False, axis=None):
    """Torii centred at C. flip: mirror vertically around y=axis."""
    def Y(y):
        y = y + oy
        return 2 * axis - y if flip else y
    def poly(pts, fill):
        draw.polygon([(C + (x - C) * sx, Y(y)) for x, y in pts], fill=fill)
    # kasagi (top beam) with upturned ends
    top, bot = [], []
    for i in range(0, 41):
        x = C - 275 + i * (550 / 40)
        u = abs(x - C) / 275
        lift = 34 * u ** 3
        top.append((x, 292 - lift))
        bot.append((x, 334 - lift * 0.8))
    poly(top + bot[::-1], color)
    # black cap along the top edge
    cap_top = [(x, y - 16) for x, y in top]
    poly(cap_top + top[::-1], cap)
    # shimaki under kasagi
    poly([(C - 238, 334), (C + 238, 334), (C + 238, 362), (C - 238, 362)], dark)
    # gakuzuka (centre strut)
    poly([(C - 18, 362), (C + 18, 362), (C + 18, 420), (C - 18, 420)], color)
    # posts, slightly leaning inwards at the top
    for sgn in (-1, 1):
        xt, xb = C + sgn * 150, C + sgn * 162
        poly([(xt - 22, 334), (xt + 22, 334), (xb + 26, 660), (xb - 26, 660)], color)
        # shading strip on the outer side
        poly([(xt + sgn * 10 - 6, 362), (xt + sgn * 22 - 0, 362), (xb + sgn * 26, 660), (xb + sgn * 12 - 6, 660)], dark)
    # nuki (tie beam), passing through the posts
    poly([(C - 212, 420), (C + 212, 420), (C + 212, 452), (C - 212, 452)], color)

def big_icon():
    img = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    R_OUT, R_IN = 500, 438
    HORIZON = 612

    # field: evening sky and water
    field = Image.new('RGBA', (S, S))
    fd = ImageDraw.Draw(field)
    sky_top, sky_h = (236, 120, 70), (250, 206, 150)
    wat_h, wat_b = (120, 146, 170), (52, 78, 104)
    for y in range(S):
        if y < HORIZON:
            t = max(0.0, (y - (C - R_IN)) / (HORIZON - (C - R_IN)))
            col = lerp(sky_top, sky_h, t ** 0.8)
        else:
            t = (y - HORIZON) / ((C + R_IN) - HORIZON)
            col = lerp(wat_h, wat_b, min(1.0, t))
        fd.line([(0, y), (S, y)], fill=col + (255,))
    # sun low over the water, behind the torii
    sun = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(sun).ellipse([C - 70, HORIZON - 150, C + 70, HORIZON - 10], fill=(255, 238, 190, 255))
    sun = sun.filter(ImageFilter.GaussianBlur(6))
    field.alpha_composite(sun)

    # torii and its reflection
    td = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    torii(ImageDraw.Draw(td))
    refl = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    torii(ImageDraw.Draw(refl), flip=True, axis=660)
    # keep the reflection in the water only, fade it, add ripples
    water = Image.new('L', (S, S), 0)
    ImageDraw.Draw(water).rectangle([0, 660, S, S], fill=255)
    a = refl.getchannel('A')
    a = ImageChops.multiply(a, water).point(lambda v: int(v * 0.38))
    refl.putalpha(a)
    refl = refl.filter(ImageFilter.GaussianBlur(2))
    field.alpha_composite(refl)
    rip = ImageDraw.Draw(field)
    # a few soft ripples, mostly where the sun's reflection falls
    for x, y, w in [(C - 40, 640, 80), (C + 10, 668, 110), (C - 70, 700, 90),
                    (C + 30, 734, 70), (C - 250, 690, 90), (C + 230, 720, 100),
                    (C - 180, 770, 70), (C + 150, 800, 60)]:
        rip.line([(x - w // 2, y), (x + w // 2, y)], fill=(235, 225, 205, 110), width=5)
    field.alpha_composite(td)

    # microscopy: fine crosshair ticks at the rim and a scale bar
    fd = ImageDraw.Draw(field)
    tick = (255, 255, 255, 170)
    for ang in range(0, 360, 90):
        rad = math.radians(ang)
        x1, y1 = C + math.cos(rad) * (R_IN - 6), C + math.sin(rad) * (R_IN - 6)
        x2, y2 = C + math.cos(rad) * (R_IN - 58), C + math.sin(rad) * (R_IN - 58)
        fd.line([(x1, y1), (x2, y2)], fill=tick, width=8)
    bx, by = C + 110, C + 330
    fd.rectangle([bx, by, bx + 150, by + 12], fill=(255, 255, 255, 230))
    fd.rectangle([bx, by - 16, bx + 8, by + 12], fill=(255, 255, 255, 230))
    fd.rectangle([bx + 142, by - 16, bx + 150, by + 12], fill=(255, 255, 255, 230))

    img.paste(field, (0, 0), circle_mask(S, R_IN))

    # eyepiece ring with a slight bevel
    ring = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse([C - R_OUT, C - R_OUT, C + R_OUT, C + R_OUT], fill=(34, 40, 56, 255))
    rd.ellipse([C - R_OUT + 14, C - R_OUT + 14, C + R_OUT - 14, C + R_OUT - 14], outline=(78, 88, 112, 255), width=10)
    rd.ellipse([C - R_IN, C - R_IN, C + R_IN, C + R_IN], fill=(0, 0, 0, 0))
    hole = circle_mask(S, R_IN)
    ra = ImageChops.subtract(ring.getchannel('A'), hole)
    ring.putalpha(ra)
    img.alpha_composite(ring)

    # glass highlight
    hl = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(hl).arc([C - R_IN + 40, C - R_IN + 40, C + R_IN - 40, C + R_IN - 40], 200, 250, fill=(255, 255, 255, 110), width=22)
    hl = hl.filter(ImageFilter.GaussianBlur(4))
    img.alpha_composite(hl)
    return img

def small_icon():
    """16-24 px: ring, flat warm field, bold torii only."""
    s = 256
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = s // 2
    d.ellipse([4, 4, s - 4, s - 4], fill=(34, 40, 56, 255))
    d.ellipse([26, 26, s - 26, s - 26], fill=(248, 178, 110, 255))
    d.pieslice([26, 26, s - 26, s - 26], 0, 180, fill=(92, 120, 146, 255))
    red = (205, 30, 38, 255)
    d.rectangle([c - 84, 70, c + 84, 92], fill=(40, 28, 30, 255))
    d.rectangle([c - 84, 86, c + 84, 104], fill=red)
    d.rectangle([c - 64, 124, c + 64, 138], fill=red)
    for sgn in (-1, 1):
        x = c + sgn * 44
        d.rectangle([x - 12, 100, x + 12, 196], fill=red)
    return img

big = big_icon()
small = small_icon()
sizes = [256, 48, 40, 32, 24, 20, 16]
frames = []
for n in sizes:
    src = small if n <= 24 else big
    frames.append(src.resize((n, n), Image.LANCZOS))
big.resize((256, 256), Image.LANCZOS).save('MView_torii_256.png')
frames[0].save('MView_torii.ico', format='ICO', sizes=[(n, n) for n in sizes],
               append_images=frames[1:])
# preview sheet
sheet = Image.new('RGBA', (256 + 20 + 48 + 10 + 40 + 10 + 32 + 10 + 24 + 10 + 20 + 10 + 16 + 20, 276), (255, 255, 255, 255))
x = 10
for f in frames:
    sheet.alpha_composite(f, (x, 10 + (256 - f.size[1]) // 2))
    x += f.size[0] + 10
dark = Image.new('RGBA', sheet.size, (40, 40, 40, 255))
x = 10
for f in frames:
    dark.alpha_composite(f, (x, 10 + (256 - f.size[1]) // 2))
    x += f.size[0] + 10
both = Image.new('RGBA', (sheet.size[0], sheet.size[1] * 2))
both.paste(sheet, (0, 0)); both.paste(dark, (0, sheet.size[1]))
both.save('MView_torii_preview.png')
print(Image.open('MView_torii.ico').info['sizes'])
