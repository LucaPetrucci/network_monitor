#!/usr/bin/env python3
"""Render the campaign Markdown report as a readable, dependency-light PDF."""

import os
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


if len(sys.argv) != 3:
    raise SystemExit(f"Usage: {sys.argv[0]} INPUT.md OUTPUT.pdf")

source = Path(sys.argv[1])
destination = Path(sys.argv[2])

PAGE_SIZE = (2339, 1654)  # A4 landscape at 200 dpi
MARGIN_X = 90
MARGIN_TOP = 80
MARGIN_BOTTOM = 75
CONTENT_WIDTH = PAGE_SIZE[0] - (2 * MARGIN_X)
FONT_DIR = Path("/usr/share/fonts/truetype/dejavu")


def font(name, size):
    return ImageFont.truetype(str(FONT_DIR / name), size)


FONTS = {
    "title": font("DejaVuSans-Bold.ttf", 42),
    "heading": font("DejaVuSans-Bold.ttf", 31),
    "subheading": font("DejaVuSans-Bold.ttf", 24),
    "body": font("DejaVuSans.ttf", 23),
    "body_bold": font("DejaVuSans-Bold.ttf", 23),
    "small": font("DejaVuSans.ttf", 19),
    "small_bold": font("DejaVuSans-Bold.ttf", 19),
    "code": font("DejaVuSansMono.ttf", 19),
    "footer": font("DejaVuSans.ttf", 16),
}


def clean_markdown(text):
    return (
        text.replace("**", "")
        .replace("`", "")
        .replace("\\→", "→")
        .strip()
    )


def text_width(draw, text, selected_font):
    box = draw.textbbox((0, 0), text, font=selected_font)
    return box[2] - box[0]


def wrap(draw, text, selected_font, width):
    words = text.split()
    if not words:
        return [""]
    lines = []
    current = words[0]
    for word in words[1:]:
        candidate = f"{current} {word}"
        if text_width(draw, candidate, selected_font) <= width:
            current = candidate
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


pages = []
image = None
draw = None
y = 0
page_number = 0


def new_page():
    global image, draw, y, page_number
    if image is not None:
        pages.append(image)
    page_number += 1
    image = Image.new("RGB", PAGE_SIZE, "white")
    draw = ImageDraw.Draw(image)
    y = MARGIN_TOP


def ensure_space(height):
    if y + height > PAGE_SIZE[1] - MARGIN_BOTTOM:
        new_page()


def draw_lines(lines, selected_font, color="#1f2937", indent=0, gap=8):
    global y
    line_height = selected_font.size + 8
    height = len(lines) * line_height + gap
    ensure_space(height)
    for line in lines:
        draw.text((MARGIN_X + indent, y), line, font=selected_font, fill=color)
        y += line_height
    y += gap


def draw_paragraph(text, selected_font=None, indent=0, color="#1f2937"):
    selected_font = selected_font or FONTS["body"]
    lines = wrap(draw, clean_markdown(text), selected_font, CONTENT_WIDTH - indent)
    draw_lines(lines, selected_font, color=color, indent=indent, gap=12)


def draw_code_block(code_lines):
    global y
    rendered_lines = []
    for code_line in code_lines:
        if not code_line:
            rendered_lines.append("")
            continue
        rendered_lines.extend(
            wrap(draw, code_line, FONTS["code"], CONTENT_WIDTH - 38)
        )
    block_height = len(rendered_lines) * (FONTS["code"].size + 8) + 30
    ensure_space(block_height + 12)
    draw.rounded_rectangle(
        (MARGIN_X, y, PAGE_SIZE[0] - MARGIN_X, y + block_height),
        radius=10,
        fill="#eef2f5",
        outline="#b8c5ce",
        width=2,
    )
    cursor_y = y + 15
    for code_line in rendered_lines:
        draw.text(
            (MARGIN_X + 18, cursor_y),
            code_line,
            font=FONTS["code"],
            fill="#17202a",
        )
        cursor_y += FONTS["code"].size + 8
    y += block_height + 14


def draw_heading(text, level):
    global y
    if level == 1:
        selected_font = FONTS["title"]
        color = "#0f3b5d"
    elif level == 2:
        selected_font = FONTS["heading"]
        color = "#155e75"
    else:
        selected_font = FONTS["subheading"]
        color = "#155e75"
    lines = wrap(draw, clean_markdown(text), selected_font, CONTENT_WIDTH)
    height = len(lines) * (selected_font.size + 10) + (25 if level < 3 else 12)
    ensure_space(height)
    for line in lines:
        draw.text((MARGIN_X, y), line, font=selected_font, fill=color)
        y += selected_font.size + 10
    if level < 3:
        draw.line((MARGIN_X, y + 2, PAGE_SIZE[0] - MARGIN_X, y + 2), fill="#99c2d1", width=3)
        y += 25
    else:
        y += 10


def table_cells(line):
    return [clean_markdown(cell) for cell in line.strip().strip("|").split("|")]


TABLE_WIDTHS = [220, 190, 210, 310, 300, 220, 190, 539]
TABLE_HEADERS = [
    "Path / Radio",
    "Direction",
    "Test",
    "Throughput\nAvg (Min–Max)",
    "Latency\nMin / Avg / Max",
    "Jitter / Loss",
    "TCP Retr.",
    "Result",
]
TABLE_FONT = font("DejaVuSans.ttf", 18)
TABLE_FONT_BOLD = font("DejaVuSans-Bold.ttf", 18)
TABLE_HEADER_FONT = font("DejaVuSans-Bold.ttf", 17)
TABLE_LINE_HEIGHT = 23
TABLE_PADDING_X = 9
TABLE_PADDING_Y = 8


def split_table_text(text, selected_font, width):
    output = []
    for explicit_line in text.split("\n"):
        output.extend(
            wrap(
                draw,
                explicit_line,
                selected_font,
                width - (2 * TABLE_PADDING_X),
            )
        )
    return output


def normalized_table_values(headers, cells):
    values = dict(zip(headers, cells))
    average = values.get("Average throughput", "—")
    minimum_maximum = values.get("Min/Max", "—")
    throughput = average
    if minimum_maximum not in ("", "—", "—/—"):
        throughput = f"{average}\n({minimum_maximum})"
    return [
        f"{values.get('Path', '')}\n{values.get('Radio', '')}",
        values.get("Direction", ""),
        values.get("Test", ""),
        throughput,
        values.get("Latency min/avg/max", ""),
        f"{values.get('Jitter', '')} / {values.get('Loss', '')}",
        values.get("Retransmissions", ""),
        values.get("Result", ""),
    ]


def table_row_layout(values, selected_font):
    groups = [
        split_table_text(value, selected_font, width)
        for value, width in zip(values, TABLE_WIDTHS)
    ]
    row_height = (
        max(len(group) for group in groups) * TABLE_LINE_HEIGHT
        + (2 * TABLE_PADDING_Y)
    )
    return groups, row_height


def draw_table_row(values, alternate=False, header=False):
    global y
    selected_font = TABLE_HEADER_FONT if header else TABLE_FONT
    groups, row_height = table_row_layout(values, selected_font)
    background = "#155e75" if header else ("#f1f5f9" if alternate else "white")
    foreground = "white" if header else "#17202a"
    x = MARGIN_X
    for group, width in zip(groups, TABLE_WIDTHS):
        draw.rectangle(
            (x, y, x + width, y + row_height),
            fill=background,
            outline="#94a3b8",
            width=2,
        )
        cursor_y = y + TABLE_PADDING_Y
        for line in group:
            draw.text(
                (x + TABLE_PADDING_X, cursor_y),
                line,
                font=selected_font,
                fill=foreground,
            )
            cursor_y += TABLE_LINE_HEIGHT
        x += width
    y += row_height


def draw_table_header():
    draw_table_row(TABLE_HEADERS, header=True)


def draw_result_table_row(headers, cells, alternate):
    values = normalized_table_values(headers, cells)
    _, row_height = table_row_layout(values, TABLE_FONT)
    if y + row_height > PAGE_SIZE[1] - MARGIN_BOTTOM:
        new_page()
        draw_table_header()
    draw_table_row(values, alternate=alternate)


lines = source.read_text(errors="replace").splitlines()
document_title = next(
    (clean_markdown(line[2:]) for line in lines if line.startswith("# ")),
    source.stem,
)
new_page()
index = 0
while index < len(lines):
    line = lines[index].rstrip()
    if line.startswith("```"):
        code_lines = []
        index += 1
        while index < len(lines) and not lines[index].rstrip().startswith("```"):
            code_lines.append(lines[index].rstrip())
            index += 1
        draw_code_block(code_lines)
    elif line.startswith("# "):
        draw_heading(line[2:], 1)
    elif line.startswith("## "):
        draw_heading(line[3:], 2)
    elif line.startswith("### "):
        draw_heading(line[4:], 3)
    elif line.startswith("|") and index + 1 < len(lines) and re.match(
        r"^\|[\s:|-]+\|$", lines[index + 1].strip()
    ):
        headers = table_cells(line)
        index += 2
        alternate = False
        ensure_space(100)
        draw_table_header()
        while index < len(lines) and lines[index].lstrip().startswith("|"):
            draw_result_table_row(headers, table_cells(lines[index]), alternate)
            alternate = not alternate
            index += 1
        y += 18
        index -= 1
    elif line.startswith("- "):
        bullet = clean_markdown(line[2:])
        bullet_lines = wrap(draw, bullet, FONTS["body"], CONTENT_WIDTH - 45)
        ensure_space(len(bullet_lines) * (FONTS["body"].size + 8) + 10)
        draw.text((MARGIN_X + 4, y), "•", font=FONTS["body_bold"], fill="#155e75")
        for bullet_line in bullet_lines:
            draw.text(
                (MARGIN_X + 38, y),
                bullet_line,
                font=FONTS["body"],
                fill="#1f2937",
            )
            y += FONTS["body"].size + 8
        y += 10
    elif re.match(r"^\d+\.\s+", line):
        number, item = line.split(".", 1)
        item_lines = wrap(
            draw,
            clean_markdown(item.strip()),
            FONTS["body"],
            CONTENT_WIDTH - 55,
        )
        ensure_space(len(item_lines) * (FONTS["body"].size + 8) + 10)
        draw.text(
            (MARGIN_X + 2, y),
            f"{number}.",
            font=FONTS["body_bold"],
            fill="#155e75",
        )
        for item_line in item_lines:
            draw.text(
                (MARGIN_X + 48, y),
                item_line,
                font=FONTS["body"],
                fill="#1f2937",
            )
            y += FONTS["body"].size + 8
        y += 10
    elif line:
        draw_paragraph(line)
    else:
        y += 8
    index += 1

if image is not None:
    pages.append(image)

total_pages = len(pages)
for number, page in enumerate(pages, start=1):
    page_draw = ImageDraw.Draw(page)
    footer = f"{document_title} — Page {number} of {total_pages}"
    page_draw.text(
        (MARGIN_X, PAGE_SIZE[1] - 45),
        footer,
        font=FONTS["footer"],
        fill="#64748b",
    )

destination.parent.mkdir(parents=True, exist_ok=True)
pages[0].save(
    destination,
    "PDF",
    resolution=200.0,
    save_all=True,
    append_images=pages[1:],
)

preview_directory = os.environ.get("PDF_PREVIEW_DIR")
if preview_directory:
    preview_path = Path(preview_directory)
    preview_path.mkdir(parents=True, exist_ok=True)
    for number, page in enumerate(pages, start=1):
        page.save(preview_path / f"page_{number}.png")
