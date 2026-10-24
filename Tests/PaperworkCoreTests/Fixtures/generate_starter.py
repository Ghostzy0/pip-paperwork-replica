#!/usr/bin/env python3
"""Regenerate PaperworkCore's original, synthetic three-page starter PDF."""

from pathlib import Path

from reportlab.lib.colors import Color, white
from reportlab.pdfgen import canvas


ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / "Sources" / "PaperworkCore" / "Resources" / "starter.pdf"
PAGE_SIZE = (595, 842)


def build(path: Path = OUTPUT) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    pdf = canvas.Canvas(str(path), pagesize=PAGE_SIZE, pageCompression=1, invariant=1)
    pdf.setTitle("Paperwork sample - Field notes")
    pdf.setAuthor("Paperwork")
    pdf.setSubject("Original synthetic sample document")

    for index in range(1, 4):
        pdf.setFillColor(white)
        pdf.rect(0, 0, *PAGE_SIZE, stroke=0, fill=1)
        lines = [
            ("SAMPLE / FIELD NOTES", 730, 11, "Helvetica-Bold"),
            (
                ("A little less paperwork." if index == 1 else "Make your mark." if index == 2 else "Keep the original."),
                666,
                29,
                "Helvetica-Bold",
            ),
            ("A local document workspace", 628, 15, "Helvetica"),
            ("PROJECT  /  MEADOW HOUSE", 564, 11, "Helvetica-Bold"),
            (f"Page {index} contains synthetic text for testing.", 530, 14, "Helvetica"),
            ("Select this sentence, then choose Highlight or Underline.", 496, 14, "Helvetica"),
            ("Add a note, draw a line, or organise the pages.", 462, 14, "Helvetica"),
            ("Your original stays unchanged when you save a copy.", 428, 14, "Helvetica"),
            ("Prepared locally. No account. No upload.", 354, 14, "Helvetica"),
            (f"SAMPLE DOCUMENT    /    {index} OF 3", 70, 11, "Helvetica"),
        ]
        for text, y, size, font in lines:
            pdf.setFont(font, size)
            pdf.setFillColor(Color(0, 0, 0))
            pdf.drawString(54, y, text)

        if index == 1:
            pdf.acroForm.textfield(
                name="Project contact",
                value="Sample person",
                x=54,
                y=252,
                width=300,
                height=30,
                fontName="Helvetica",
                fontSize=14,
                textColor=Color(0, 0, 0),
                fillColor=Color(0.95, 0.95, 0.95),
                borderColor=Color(0.55, 0.55, 0.55),
                borderWidth=0.5,
                forceBorder=True,
            )
        pdf.showPage()

    pdf.save()


if __name__ == "__main__":
    build()
