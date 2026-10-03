# Картинка для предпросмотра ссылки coin.edudev.kz в мессенджерах (Open Graph,
# 1200×630). Запуск: python3 design/og/make_og.py → app/web/og.png.
# Нужен Pillow (python3 -m pip install pillow). Цифры на макете условные.
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'app' / 'web' / 'og.png'
FONTS = Path('/System/Library/Fonts/Supplemental')
W, H = 1200, 630
BG, CARD, LINE = (18, 21, 26), (28, 33, 40), (44, 51, 60)
TEXT, TEXT2 = (240, 242, 245), (150, 158, 170)
GREEN, GREEN2, WARN, EXPENSE = (46, 160, 120), (31, 94, 79), (230, 170, 60), (230, 95, 95)


def font(size, bold=False):
    for name in (['Arial Bold.ttf', 'Arial Unicode.ttf'] if bold else ['Arial.ttf', 'Arial Unicode.ttf']):
        p = FONTS / name
        if p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


def money(x, y, text, font_, fill, anchor='la'):
    """Сумма со знаком тенге: в системных шрифтах его нет, рисуем «T» с чертой."""
    d.text((x, y), text, font=font_, fill=fill, anchor=anchor)
    w = font_.getlength(text)
    left = x if anchor[0] == 'l' else x - w
    tx = left + w + font_.size * 0.22
    d.text((tx, y), 'T', font=font_, fill=fill, anchor='l' + anchor[1])
    tw = font_.getlength('T')
    top = y - (font_.size * 0.72 if anchor[1] == 'a' else font_.size * 0.72 - font_.size * 0.0) if False else None
    bb = d.textbbox((tx, y), 'T', font=font_, anchor='l' + anchor[1])
    bar_y = bb[1] + (bb[3] - bb[1]) * 0.22
    d.rectangle((bb[0] + tw * 0.05, bar_y, bb[0] + tw * 0.95, bar_y + max(2, font_.size * 0.07)), fill=fill)


img = Image.new('RGB', (W, H), BG)
# мягкое зелёное свечение справа
glow = Image.new('RGB', (W, H), BG)
g = ImageDraw.Draw(glow)
g.ellipse((700, -150, 1400, 500), fill=(24, 48, 40))
glow = glow.filter(ImageFilter.GaussianBlur(120))
img = Image.blend(img, glow, 0.9)
d = ImageDraw.Draw(img)

# ----- левая часть: заголовок
d.rounded_rectangle((70, 64, 126, 120), 16, fill=GREEN2)
money(84, 92, '', font(30, True), TEXT, anchor='lm')
d.text((142, 92), 'FamCoin', font=font(40, True), fill=TEXT, anchor='lm')

d.text((70, 170), 'Семейные деньги', font=font(56, True), fill=TEXT, anchor='ls')
d.text((70, 236), 'под контролем', font=font(56, True), fill=TEXT, anchor='ls')
d.text((70, 286), 'Учёт за 2 минуты в день — для Казахстана', font=font(26), fill=TEXT2, anchor='ls')

bullets = ['Дневной лимит и перенос остатка', 'Цели-копилки, долги, плановые платежи', 'Выписка Kaspi — одной кнопкой', 'ИИ-консультант по вашим цифрам']
y = 340
for b in bullets:
    d.ellipse((72, y - 11, 94, y + 11), fill=GREEN)
    d.line((77, y, 82, y + 5, 90, y - 5), fill=BG, width=3)
    d.text((110, y), b, font=font(26), fill=TEXT, anchor='lm')
    y += 46
d.text((70, 572), 'coin.edudev.kz', font=font(26, True), fill=GREEN, anchor='ls')

# ----- правая часть: телефон с карточками
PX, PY, PW, PH = 760, 40, 380, 760  # телефон обрезан снизу краем картинки
d.rounded_rectangle((PX, PY, PX + PW, PY + PH), 44, fill=(10, 12, 15), outline=LINE, width=3)
d.rounded_rectangle((PX + 130, PY + 16, PX + PW - 130, PY + 34), 9, fill=(30, 34, 40))


def card(y0, h):
    d.rounded_rectangle((PX + 22, y0, PX + PW - 22, y0 + h), 20, fill=CARD)
    return PX + 42, y0 + 20


def bar(x, y, w, ratio, color):
    d.rounded_rectangle((x, y, x + w, y + 10), 5, fill=LINE)
    d.rounded_rectangle((x, y, x + max(12, int(w * ratio)), y + 10), 5, fill=color)


# карточка 1: остаток и лимит на сегодня
x, y = card(PY + 60, 150)
d.text((x, y), 'На счетах', font=font(18), fill=TEXT2, anchor='la')
money(x, y + 26, '352 400', font(38, True), TEXT)
d.text((x, y + 78), 'Доступно сегодня', font=font(18), fill=TEXT2, anchor='la')
money(x + 270, y + 78, '3 450', font(20, True), GREEN, anchor='ra')
bar(x, y + 108, 296, 0.69, GREEN)

# карточка 2: доходы растут
x, y = card(PY + 228, 190)
d.text((x, y), 'Доходы по месяцам', font=font(18), fill=TEXT2, anchor='la')
d.text((x + 296, y), '+18 %', font=font(20, True), fill=GREEN, anchor='ra')
vals = [0.42, 0.5, 0.47, 0.62, 0.7, 0.86]
months = ['апр', 'май', 'июн', 'июл', 'авг', 'сен']
bx, by, bw, bh = x, y + 40, 296, 100
for i, v in enumerate(vals):
    cx = bx + i * (bw // 6)
    top = by + bh - int(bh * v)
    d.rounded_rectangle((cx + 6, top, cx + 38, by + bh), 6, fill=GREEN if i == 5 else GREEN2)
    d.text((cx + 22, by + bh + 16), months[i], font=font(15), fill=TEXT2, anchor='mm')

# карточка 3: цель
x, y = card(PY + 436, 120)
d.text((x, y), 'Цель · Отпуск', font=font(18), fill=TEXT2, anchor='la')
money(x, y + 26, '180 000 из 300 000', font(22, True), TEXT)
d.text((x + 296, y + 26), '60 %', font=font(20, True), fill=GREEN, anchor='ra')
bar(x, y + 66, 296, 0.6, GREEN)

# карточка 4: лимит категории
x, y = card(PY + 574, 120)
d.text((x, y), 'Лимит · Кафе', font=font(18), fill=TEXT2, anchor='la')
money(x, y + 26, '8 200 из 10 000', font(22, True), TEXT)
d.text((x + 296, y + 26), '82 %', font=font(20, True), fill=WARN, anchor='ra')
bar(x, y + 66, 296, 0.82, WARN)

OUT.parent.mkdir(parents=True, exist_ok=True)
img.save(OUT, optimize=True)
print(OUT, img.size)
