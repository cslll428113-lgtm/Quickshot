from PIL import Image, ImageDraw, ImageFilter

S = 1024
scale = 4
canvas = Image.new("RGBA", (S * scale, S * scale), (0, 0, 0, 0))
draw = ImageDraw.Draw(canvas)

def q(v):
    return int(v * scale)

def rounded_box(box, radius, fill, outline=None, width=1):
    draw.rounded_rectangle(tuple(q(v) for v in box), radius=q(radius), fill=fill,
                           outline=outline, width=q(width))

# Soft dark-violet base with a subtle diagonal color shift.
mask = Image.new("L", canvas.size, 0)
ImageDraw.Draw(mask).rounded_rectangle((q(62), q(62), q(962), q(962)), radius=q(224), fill=255)
gradient = Image.new("RGBA", canvas.size)
gp = gradient.load()
for y in range(canvas.size[1]):
    for x in range(canvas.size[0]):
        t = (x + y) / (2 * canvas.size[0])
        gp[x, y] = (int(37 - 21 * t), int(36 - 19 * t), int(62 - 35 * t), 255)
canvas.alpha_composite(Image.composite(gradient, Image.new("RGBA", canvas.size), mask))
draw = ImageDraw.Draw(canvas)
rounded_box((83, 83, 941, 941), 204, None, (255, 255, 255, 22), 10)

# Crop-frame glow.
glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
line = (112, 190, 255, 235)
w = q(70)
r = q(34)
segments = [
    ((q(266), q(432)), (q(266), q(304)), (q(304), q(266)), (q(432), q(266))),
    ((q(592), q(266)), (q(720), q(266)), (q(758), q(304)), (q(758), q(432))),
    ((q(758), q(592)), (q(758), q(720)), (q(720), q(758)), (q(592), q(758))),
    ((q(432), q(758)), (q(304), q(758)), (q(266), q(720)), (q(266), q(592))),
]
for pts in segments:
    gd.line(pts, fill=line, width=w, joint="curve")
blurred = glow.filter(ImageFilter.GaussianBlur(q(18)))
canvas.alpha_composite(blurred)
canvas.alpha_composite(glow)
draw = ImageDraw.Draw(canvas)

# White sparkle and pink accent dot.
cx, cy = q(515), q(500)
outer = q(140)
inner = q(38)
spark = [
    (cx, cy - outer), (cx + inner, cy - inner), (cx + outer, cy),
    (cx + inner, cy + inner), (cx, cy + outer), (cx - inner, cy + inner),
    (cx - outer, cy), (cx - inner, cy - inner),
]
draw.polygon(spark, fill=(255, 255, 255, 255))
draw.ellipse((q(696), q(266), q(758), q(328)), fill=(255, 140, 207, 255))

result = canvas.resize((S, S), Image.Resampling.LANCZOS)
result.save("QuickShot-icon.png")
result.save("QuickShot.ico", bitmap_format="bmp",
            sizes=[(16, 16), (24, 24), (32, 32), (48, 48),
                   (64, 64), (128, 128), (256, 256)])
