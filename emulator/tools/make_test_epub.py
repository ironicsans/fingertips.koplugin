"""Build a tiny EPUB with plain paragraphs, for testing text selection."""
import sys, zipfile

paras = [
    "The harbour was quiet that morning. A thin fog lay across the water, and the fishing boats rocked gently at their moorings while the gulls waited on the posts for someone to begin the day.",
    "Mara walked the length of the pier twice before she found the right boat. It was smaller than she had expected, painted a faded green, with a name stencilled on the bow in letters that had mostly worn away.",
    "She set her bag down on the deck and listened. Somewhere below, an engine coughed, caught, and settled into a slow and patient rhythm, like an old dog turning over in its sleep.",
    "The captain appeared a moment later, wiping his hands on a rag. He looked at her, then at the bag, then at the sky, as if all three were questions he would have to answer before noon.",
    "They left the harbour as the fog began to lift. Behind them the town grew small and bright, its windows catching the first real light of the morning, and ahead of them the sea opened out, flat and grey and endless.",
    "For a long time neither of them spoke. The gulls followed for a mile or so and then gave up, wheeling back toward the shore, and after that there was only the engine and the water and the wide, pale sky.",
]
body = "\n".join(f"<p>{p}</p>" for p in paras * 2)
xhtml = f"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter One</title></head>
<body><h1>Chapter One</h1>
{body}
</body></html>"""
opf = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
<dc:identifier id="id">lifted-selection-test</dc:identifier>
<dc:title>Selection Test</dc:title><dc:language>en</dc:language>
<meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>
</metadata>
<manifest>
<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
</manifest>
<spine><itemref idref="ch1"/></spine>
</package>"""
nav = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Nav</title></head>
<body><nav epub:type="toc"><ol><li><a href="ch1.xhtml">Chapter One</a></li></ol></nav></body></html>"""
container = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
<rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    z.writestr("META-INF/container.xml", container, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/content.opf", opf, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/nav.xhtml", nav, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("OEBPS/ch1.xhtml", xhtml, compress_type=zipfile.ZIP_DEFLATED)
