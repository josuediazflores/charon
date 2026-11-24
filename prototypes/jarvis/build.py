import base64
import io
import json
import math
import re
import subprocess
from html import escape
from pathlib import Path
from urllib.parse import unquote, urlsplit

from PIL import Image


here = Path(__file__).resolve().parent
root = here.parents[1]
example = here / "fixtures"
run = example / "assignments/chicago-internships/runs/2026-11-24"
native = root / "mac/Sources/Kit"
pandoc = "pandoc"


def data_uri(raw, kind):
    return "data:" + kind + ";base64," + base64.b64encode(raw).decode("ascii")


def glyph(name):
    section = (native / "PixelGlyph.swift").read_text().split(f"case .{name}:", 1)[1].split("]", 1)[0]
    rows = re.findall(r'"([.#]{7})"', section)
    assert len(rows) == 7
    bitmap = Image.new("RGBA", (7, 7))
    for y, line in enumerate(rows):
        for x, pixel in enumerate(line):
            if pixel == "#":
                bitmap.putpixel((x, y), (255, 255, 255, 255))
    image = io.BytesIO()
    bitmap.save(image, format="PNG")
    return data_uri(image.getvalue(), "image/png")


def rail():
    src = (native / "SidebarView.swift").read_text()
    specs = re.findall(r'SidebarItemSpec\(id: "(\w+)", icon: \.(pixel|text)\(([^)]+)\), label: "([^"]+)"\)', src)
    assert len(specs) == 8
    rows = {}
    for key, kind, mark, label in specs:
        if kind == "pixel":
            graphic = '<i class="pixel" aria-hidden="true" style="--glyph:url(' + glyph(mark.lstrip(".")) + ')"></i>'
        else:
            graphic = '<span class="rail-symbol" aria-hidden="true">' + escape(mark.strip('"')) + '</span>'
        if key == "jarvis":
            rows[key] = (
                '<details id="jarvis-nav" open><summary class="rail-row">'
                f'{graphic}<span>{label}</span><i class="disclosure" aria-hidden="true"></i></summary>'
                '<div class="subnav"><a href="#brief">Daily Brief</a>'
                '<a href="#tasks">Overnight tasks</a></div></details>'
            )
        else:
            rows[key] = f'<span class="rail-row" aria-disabled="true">{graphic}<span>{label}</span></span>'

    groups = [
        ("System", ("overview", "hardware")),
        ("Work", ("cmo", "mail", "messages")),
        ("Assistants", ("chat", "jarvis")),
    ]
    sections = []
    for label, keys in groups:
        items = "\n".join("              " + rows[key] for key in keys)
        sections.append(f'            <div class="rail-group">\n              <h2>{label}</h2>\n{items}\n            </div>')
    return (
        '<div class="rail-groups">\n' + "\n".join(sections) + '\n          </div>\n'
        f'          <div class="rail-settings">{rows["settings"]}</div>'
    )


def strip_frontmatter(raw):
    return re.sub(r"\A---\n.*?\n---\n+", "", raw, flags=re.S).strip()


def route_link(match):
    raw = unquote(match[1])
    uri = urlsplit(raw)
    key = Path(uri.path).name
    if key == "sources.md":
        key = uri.fragment
    destinations = {
        "maple-studio": "note/maple", "lakefront-labs": "note/lakefront",
        "2.md": "note/delivered", "Summer 2027 internships in Chicago.md": "note/current",
        "desk-stand.md": "note/stand", "keyboard-side.md": "note/keyboard",
        "microphone.md": "report/microphone", "summary.md": "report/chicago",
    }
    if key not in destinations:
        raise ValueError(f"Unmapped Markdown link {raw!r}")
    return 'href="#' + destinations[key] + '"'


def document(raw, **metadata):
    title_line, body = strip_frontmatter(raw).split("\n", 1)
    assert title_line.startswith("# ")
    html = subprocess.run(
        [pandoc, "--from=markdown-smart", "--to=html5", "--wrap=none"],
        input=body.strip(), text=True, capture_output=True, check=True,
    ).stdout
    html = re.sub(r'href="([^"]+)"', route_link, html)
    html = html.replace('src="../assets/lakefront.jpg"', 'data-illustration width="1440" height="576"')
    words = re.sub(r"<[^>]+>", " ", html)
    return dict(title=title_line[2:], html=html, raw=raw.strip() + "\n",
                minutes=max(1, math.ceil(len(words.split()) / 210)), **metadata)


def read(name):
    return (example / name).read_text()


docs = {
    "report/chicago": document(read("chicago.md"), date="November 24, 2026", stamp="Updated 6:18 a.m. PT", short="Internship search", back="tasks"),
    "report/microphone": document(read("microphone.md"), date="November 23, 2026", stamp="", short="Microphone test", back="tasks"),
    "note/delivered": document((example / "revisions/chicago-internships/2.md").read_text(), date="Career project", stamp="Revision 2 · As delivered", short="Delivered list", back="report/chicago"),
    "note/current": document((example / "projects/career/Summer 2027 internships in Chicago.md").read_text(), date="Career project", stamp="Revision 3 · Current list", short="Current list", back="report/chicago"),
    "note/stand": document(read("desk-stand.md"), date="Voice project", stamp="Trial note", short="Desk stand", back="report/microphone"),
    "note/keyboard": document(read("keyboard-side.md"), date="Voice project", stamp="Trial note", short="Keyboard-side trial", back="report/microphone"),
}
postings = strip_frontmatter((run / "sources.md").read_text())
for key, name, text in zip(("maple", "lakefront"), ("Maple Studio", "Lakefront Labs"), re.split(r"(?m)^## ", postings)[1:]):
    heading, body = text.split("\n", 1)
    assert heading == name
    source_doc = "# " + heading + "\n\n" + body.strip() + "\n\n[Read the internship report](summary.md)."
    docs["note/" + key] = document(source_doc, date="Employer posting", stamp="Example source", short=name, back="report/chicago")


data = dict(
    docs=docs,
    orb="assets/orb.png",
    cover="assets/lakefront.jpg",
    script=(example / "daily/2026-11-24.md").read_text().split("## Spoken brief\n\n")[1].strip(),
)
payload = {
    "BRAND": glyph("brand"), "NAV": rail(),
    "CLOSE": '<svg class="icon" aria-hidden="true" viewBox="0 0 24 24"><path d="m6 6 12 12M18 6 6 18"/></svg>',
    "DATA": json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c"),
}
page = re.sub(r"@@([A-Z]+)@@", lambda m: payload[m[1]], (here / "frame.html").read_text())
assert not re.search(r"@@[A-Z]+@@", page)
target = here / "index.html"
target.write_text(page)
print(f"{target.name} · {target.stat().st_size:,} bytes · {len(docs)} Markdown documents")
