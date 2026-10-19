"""Genera il logo PDE Analisi nello stile di Giro Manager.

Stesso pavone del PDE Hub (ritagliato dal logo Giro Manager), stessi colori e
font (Century Gothic): "PDE" blu notte in grassetto, "ANALISI" blu, motto sotto.
Uso:  py scripts/crea_logo.py   (dalla cartella del progetto)
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

QUI = Path(__file__).resolve().parent.parent
GIRO = QUI.parent / "GIRO MANAGER" / "public" / "logo"
OUT = QUI / "logo"
OUT.mkdir(exist_ok=True)

NAVY, BLU, CIANO = (0, 28, 80, 255), (0, 92, 224, 255), (16, 172, 224, 255)
FONT_B = "C:/Windows/Fonts/GOTHICB.TTF"
FONT_R = "C:/Windows/Fonts/GOTHIC.TTF"

sorgente = Image.open(GIRO / "giro-manager-logo.png").convert("RGBA")
pavone = sorgente.crop((1797, 0, 2181, sorgente.height))

H = sorgente.height
CAP_TOP, CAP_BOTTOM = 204, 367          # altezza maiuscole come in Giro Manager
TAG_TOP = 424

def font_per_cap(path, cap):
    """Font con altezza delle maiuscole pari a `cap` pixel."""
    size = cap
    for _ in range(30):
        f = ImageFont.truetype(path, size)
        b = f.getbbox("E")
        h = b[3] - b[1]
        if abs(h - cap) <= 1:
            return f
        size = round(size * cap / h)
    return f

cap = CAP_BOTTOM - CAP_TOP
f_pde = font_per_cap(FONT_B, cap)
f_fest = font_per_cap(FONT_R, cap)
f_tag = font_per_cap(FONT_R, 26)

def larghezza_spaziata(testo, font, spazio):
    return sum(font.getlength(c) for c in testo) + spazio * (len(testo) - 1)

def scrivi_spaziato(d, x, y, testo, font, colore, spazio):
    for c in testo:
        d.text((x, y), c, font=font, fill=colore)
        x += font.getlength(c) + spazio
    return x

X0 = 41
w_pde = f_pde.getlength("PDE")
gap = 52
w_fest = f_fest.getlength("ANALISI")
x_pavone = int(X0 + w_pde + gap + w_fest + 30)
W = x_pavone + pavone.width + 38

img = Image.new("RGBA", (W, H), (255, 255, 255, 0))
d = ImageDraw.Draw(img)
off_b = f_pde.getbbox("E")[1]
off_r = f_fest.getbbox("E")[1]
d.text((X0, CAP_TOP - off_b), "PDE", font=f_pde, fill=NAVY)
d.text((X0 + w_pde + gap, CAP_TOP - off_r), "ANALISI", font=f_fest, fill=BLU)

# Motto: tre parole con i tre colori, separate da barre, molto spaziato
spazio = 9
off_t = f_tag.getbbox("E")[1]
x = X0 + 3
parti = [("RACCOGLI.", NAVY), ("I", NAVY), ("ANALIZZA.", BLU), ("I", BLU), ("DECIDI.", CIANO)]
for i, (t, col) in enumerate(parti):
    x = scrivi_spaziato(d, x, TAG_TOP - off_t, t, f_tag, col, spazio)
    x += 22

img.alpha_composite(pavone, (x_pavone, 0))
img = img.crop(img.getbbox())
pad = 40
logo = Image.new("RGBA", (img.width + 2 * pad, img.height + 2 * pad), (255, 255, 255, 0))
logo.alpha_composite(img, (pad, pad))

logo.save(OUT / "pde-analisi-logo.png")
bianco = Image.new("RGB", logo.size, (255, 255, 255))
bianco.paste(logo, mask=logo.split()[3])
bianco.save(OUT / "pde-analisi-logo-bianco.png")
for w in (480, 960):
    h = round(logo.height * w / logo.width)
    logo.resize((w, h), Image.LANCZOS).save(OUT / f"pde-analisi-logo-{w}.png")

# Versione per sfondi scuri: PDE in bianco al posto del blu notte
scuro = logo.copy()
px = scuro.load()
for yy in range(scuro.height):
    for xx in range(scuro.width):
        r, g, b, a = px[xx, yy]
        if a and (r, g, b) == NAVY[:3] or (a and abs(r - 0) < 20 and abs(g - 28) < 20 and abs(b - 80) < 25 and xx < scuro.width - pavone.width - pad):
            px[xx, yy] = (255, 255, 255, a)
h = round(scuro.height * 960 / scuro.width)
scuro.resize((960, h), Image.LANCZOS).save(OUT / "pde-analisi-logo-scuro-960.png")

# Icona e favicon: stesso pavone di Giro Manager / Hub
Image.open(GIRO / "giro-manager-icona.png").save(OUT / "pde-analisi-icona.png")
Image.open(GIRO / "favicon-64.png").save(OUT / "favicon-64.png")
print("Logo creato in", OUT, logo.size)
