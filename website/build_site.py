"""Builds the static Aperta site into website/aperta/.

  set APERTA_SUPPORT_EMAIL=<the public support address>        (Windows cmd)
  $env:APERTA_SUPPORT_EMAIL = "<the public support address>"    (PowerShell)
  python website/build_site.py

The support address is read from the environment so that it is set by a person and never hard coded in
this script. It is shown on the pages as selectable text (no mailto link, which is unreliable in many
mail setups and invites scraping). The same address is already printed in docs/legal/*.md.

Optional: APERTA_SITE_OUT=<folder> writes the pages somewhere else (used for review builds).

Writes index.html, privacy/index.html, terms/index.html, support/index.html, sitemap.xml, robots.txt.
The privacy and terms pages are generated from docs/legal/*.md, so edit the Markdown and re-run this script.
The draft notice block in those files (between the DRAFT-NOTICE markers) is stripped from the web pages.
Assets (CSS, images) live in website/aperta/assets (see website/make_site_assets.py).
Pure standard library.
"""
import html
import json
import math
import os
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_SITE = ROOT / "website" / "aperta"
OUT = Path(os.environ.get("APERTA_SITE_OUT") or SRC_SITE)
LEGAL = ROOT / "docs" / "legal"

BASE = "https://ecomswiftllc.github.io/aperta/"
SUPPORT_EMAIL = os.environ.get("APERTA_SUPPORT_EMAIL", "").strip()
UPDATED = "2026-11-17"
SITE_NAME = "Photo Editor & Collage: Aperta"

if not SUPPORT_EMAIL:
    sys.exit("Set APERTA_SUPPORT_EMAIL to the public support address before building (see the top of this file).")


# ----------------------------------------------------------------------------- lens drawing
def lens_svg():
    """The hero drawing: an aperture of six blades inside a lens barrel with an f-stop scale.
    Blade geometry matches ApertureMark in Sources/Theme/Components.swift (openness 0.28)."""
    c, R, openness = 240, 140, 0.28
    beta = math.acos(openness)
    vr = R * openness / math.cos(math.pi / 6)
    blades = []
    for i in range(6):
        a = i / 6 * 2 * math.pi
        x1, y1 = c + math.cos(a + beta) * R, c + math.sin(a + beta) * R
        x2, y2 = c + math.cos(a - math.pi / 6) * vr, c + math.sin(a - math.pi / 6) * vr
        blades.append(f'<line class="blade" x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}"/>')
    ticks = []
    for i in range(72):
        ang = math.radians(i * 5 - 90)
        major = i % 6 == 0
        r1, r2 = 206, 206 + (13 if major else 6)
        ticks.append(f"M{c + math.cos(ang) * r1:.2f} {c + math.sin(ang) * r1:.2f}"
                     f"L{c + math.cos(ang) * r2:.2f} {c + math.sin(ang) * r2:.2f}")
    nums = []
    for i, label in enumerate(["1.4", "2", "2.8", "4", "5.6", "8", "11", "16"]):
        deg = -90 + i * 45
        ang = math.radians(deg)
        x, y = c + math.cos(ang) * 176, c + math.sin(ang) * 176
        rot = deg + 90
        if 0 < deg < 180:  # bottom half: turn the text so it still reads upright
            rot = deg - 90
        nums.append(f'<text class="fnum" transform="translate({x:.2f} {y:.2f}) rotate({rot})">{label}</text>')
    return f"""<svg viewBox="0 0 480 480" aria-hidden="true" focusable="false">
  <defs>
    <linearGradient id="brassGrad" gradientUnits="userSpaceOnUse" x1="0" y1="90" x2="0" y2="390">
      <stop offset="0" stop-color="#E6C78C"/><stop offset="1" stop-color="#B89252"/>
    </linearGradient>
    <radialGradient id="lightGrad" cx="50%" cy="50%" r="50%">
      <stop offset="0" stop-color="#D2AE6E" stop-opacity=".30"/><stop offset="1" stop-color="#D2AE6E" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <circle class="barrel" cx="{c}" cy="{c}" r="236"/>
  <circle class="barrel" cx="{c}" cy="{c}" r="162"/>
  <path class="scale" d="{''.join(ticks)}"/>
  {''.join(nums)}
  <circle class="glow" cx="{c}" cy="{c}" r="{R}" fill="url(#lightGrad)"/>
  <g class="blades"><circle class="blade" cx="{c}" cy="{c}" r="{R}"/>{''.join(blades)}</g>
</svg>"""


# ----------------------------------------------------------------------------- shell
def head(title, description, path, extra_head="", root=""):
    canonical = BASE + path
    t = html.escape(title)
    d = html.escape(description)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{t}</title>
<meta name="description" content="{d}">
<link rel="canonical" href="{canonical}">
<meta name="theme-color" content="#0C0D0F">
<meta name="color-scheme" content="dark">
<link rel="icon" href="{root}assets/favicon.svg" type="image/svg+xml">
<link rel="icon" href="{root}assets/favicon-32.png" type="image/png" sizes="32x32">
<link rel="apple-touch-icon" href="{root}assets/apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="{html.escape(SITE_NAME)}">
<meta property="og:title" content="{t}">
<meta property="og:description" content="{d}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{BASE}assets/og-image.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="The Aperta app icon, a brass aperture, next to the name Photo Editor &amp; Collage: Aperta">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{t}">
<meta name="twitter:description" content="{d}">
<meta name="twitter:image" content="{BASE}assets/og-image.png">
<link rel="stylesheet" href="{root}assets/site.css">
{extra_head}</head>
<body>
<a class="skip" href="#main">Skip to content</a>
"""


def header(root, current=""):
    def a(href, text, key):
        cur = ' aria-current="page"' if key == current else ""
        return f'<a href="{href}"{cur}>{text}</a>'
    home = root or "./"
    return f"""<header class="site-header">
  <div class="wrap">
    <a class="brand" href="{home}"><img src="{root}assets/aperta-mark.svg" alt="" width="34" height="34">Aperta</a>
    <nav class="nav" aria-label="Main">
      {a(home + '#editor', 'Editor', 'e')}
      {a(home + '#tools', 'Tools', 't')}
      {a(home + '#private', 'Privacy', 'p')}
      {a(home + '#free', 'Free with ads', 'a')}
      {a(home + '#faq', 'FAQ', 'q')}
      {a(root + 'support/', 'Support', 'support')}
    </nav>
  </div>
</header>
"""


def footer(root):
    home = root or "./"
    return f"""<footer class="site-footer">
  <div class="wrap">
    <div>
      <h2>Photo Editor &amp; Collage: Aperta</h2>
      <p>A free photo editor for iPhone. Your photos are edited on your device. Coming soon to the App Store.</p>
    </div>
    <nav aria-label="Footer">
      <h2>Pages</h2>
      <ul>
        <li><a href="{home}">Home</a></li>
        <li><a href="{root}support/">Support</a></li>
        <li><a href="{root}privacy/">Privacy policy</a></li>
        <li><a href="{root}terms/">Terms of use</a></li>
      </ul>
    </nav>
    <div>
      <h2>Ecom Swift LLC</h2>
      <p>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p>
      <p class="email">{html.escape(SUPPORT_EMAIL)}</p>
    </div>
    <p class="legalline">&copy; 2026 Ecom Swift LLC. Apple, iPhone and the App Store are trademarks of Apple Inc. Aperta is not affiliated with Apple or Google.</p>
  </div>
</footer>
</body>
</html>
"""


# ----------------------------------------------------------------------------- home
EMAIL_TEXT = f'<span class="email">{html.escape(SUPPORT_EMAIL)}</span>'

FAQ = [
    ("Is Aperta really free?",
     "<p>Yes. There is no subscription, no in-app purchase and no paid version. Ads from Google AdMob pay for the app: a banner on the Home screen, and one rewarded video that you choose to watch before you save or share a finished photo.</p>"),
    ("Are my photos uploaded anywhere?",
     "<p>No. Editing, background removal, collage, compress, resize, convert, watermark, ID photos and photo details all run on your device. We never receive your photos.</p>"),
    ("Do I need an account?",
     "<p>No. There is no sign-in and no sign-up.</p>"),
    ("Why am I asked to watch an ad?",
     "<p>Before you save or share a photo, the app offers one short video that you choose to watch. One watched ad covers your exports for 2 minutes, so you can save several photos in a row. If you choose Not now, nothing is exported and you can try again any time. If no ad is available, for example when you are offline, the export goes ahead anyway.</p>"),
    ("Does it need photo library access?",
     "<p>Not to edit. You pick photos with the iOS photo picker, and Aperta sees only the ones you choose. To save a result, the app asks for add-only permission, which lets it add pictures and does not let it read your library.</p>"),
    ("What happens if I do not allow tracking?",
     "<p>The app works the same. The ads you see will be less personalised. You can change the choice any time in iOS Settings under Privacy and Security, then Tracking. Aperta does not track you itself.</p>"),
    ("Which devices does it run on?",
     "<p>iPhone with iOS 17 or later.</p>"),
    ("Which file formats can I save?",
     "<p>The editor saves JPG, PNG and HEIC. The Convert tool also makes PDF files from photos.</p>"),
    ("When can I download it?",
     "<p>Aperta is not released yet. This page will link to the App Store listing once the app is live.</p>"),
    ("Who makes Aperta?",
     "<p>Ecom Swift LLC, a company registered in Wyoming, United States. You can reach us on the <a href=\"support/\">support page</a>.</p>"),
]


def jsonld_app():
    data = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": SITE_NAME,
        "alternateName": "Aperta",
        "url": BASE,
        "applicationCategory": "MultimediaApplication",
        "operatingSystem": "iOS 17.0 or later",
        "description": "A free photo editor for iPhone. Crop, adjust, filter, remove backgrounds and make collages, and compress, resize, convert and watermark photos, make ID photos and remove location data. Photos are processed on the device. Supported by ads.",
        "image": BASE + "assets/icon-512.png",
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
        "publisher": {"@type": "Organization", "name": "Ecom Swift LLC", "url": "https://www.ecomswiftllc.com/",
                      "address": {"@type": "PostalAddress", "streetAddress": "30 N Gould St #37906",
                                  "addressLocality": "Sheridan", "addressRegion": "WY", "postalCode": "82801",
                                  "addressCountry": "US"}},
        "featureList": [
            "Crop, straighten, rotate and flip",
            "13 adjustment dials and auto enhance",
            "25 original filters",
            "Text, stickers, emoji and shapes",
            "Drawing with pen, marker and neon",
            "Blur and pixelate brush",
            "Background removal on the device",
            "Collage, compress, resize and convert",
            "Watermark, ID and passport photos",
            "View and remove photo location data",
            "Works without an account",
        ],
    }
    return '<script type="application/ld+json">\n' + json.dumps(data, indent=2) + "\n</script>\n"


def jsonld_faq():
    plain = lambda s: html.unescape(re.sub(r"<[^>]+>", "", s))
    data = {"@context": "https://schema.org", "@type": "FAQPage",
            "mainEntity": [{"@type": "Question", "name": q,
                            "acceptedAnswer": {"@type": "Answer", "text": plain(a)}} for q, a in FAQ]}
    return '<script type="application/ld+json">\n' + json.dumps(data, indent=2) + "\n</script>\n"


def build_index():
    title = "Photo Editor & Collage: Aperta | Free photo editor for iPhone"
    desc = "Free photo editor for iPhone. Crop, adjust, filter, remove backgrounds, make collages, resize, compress, convert and watermark photos. Edited on your device, with no account. Coming soon."
    faq_html = "\n".join(
        f'        <details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in FAQ)
    tools = [
        ("Collage", "Combine two to nine photos in a clean layout."),
        ("Compress", "Make files smaller without visible loss."),
        ("Resize", "Set exact sizes, or start from a preset for a social network."),
        ("Convert", "Change photos between JPG, PNG and HEIC, or turn them into one PDF."),
        ("Watermark", "Add your name as text, or your logo, to many photos at once."),
        ("ID photo", "Make passport and visa photos at the right size, with a print sheet."),
        ("Photo details", "See where and how a photo was taken, then save a copy without the location or camera details."),
    ]
    tools_html = "\n".join(f'          <li><h3>{n}</h3><p>{d}</p></li>' for n, d in tools)
    tools_html += '\n          <li class="note"><p>All seven tools run on your device. None of them uploads a photo.</p></li>'

    body = head(title, desc, "", jsonld_app() + jsonld_faq(), root="") + header("", "") + f"""
<main id="main">
  <section class="hero" aria-labelledby="h1">
    <div class="wrap">
      <div>
        <h1 id="h1">A complete photo studio that stays on your phone.</h1>
        <p class="lede">Aperta edits, combines, resizes and compresses your photos on your iPhone. It is free, there is no account, and every photo is processed on your device.</p>
        <p class="status">Coming soon to the App Store</p>
        <p class="small hero-note">The app has not been released yet, so there is no download link. Questions before launch are welcome on the <a href="support/">support page</a>.</p>
      </div>
      <div class="lens">
        {lens_svg()}
      </div>
    </div>
  </section>

  <section class="section" id="editor" aria-labelledby="h-editor">
    <div class="wrap">
      <h2 id="h-editor">An editor with real controls</h2>
      <div class="section-body">
        <dl class="defs">
          <div><dt>Crop, straighten, rotate and flip</dt><dd>Frame the picture you meant to take, and level a crooked horizon.</dd></div>
          <div><dt>Adjust with 13 dials</dt><dd>Fine control over light, colour and detail, plus auto enhance when you want a quick start.</dd></div>
          <div><dt>25 original filters</dt><dd>Looks made for Aperta, from subtle to strong.</dd></div>
          <div><dt>Text, stickers, emoji and shapes</dt><dd>Add a caption, a label or a detail, and place it where you want it.</dd></div>
          <div><dt>Draw</dt><dd>Sketch or annotate with a pen, a marker or a neon brush.</dd></div>
          <div><dt>Blur and pixelate brush</dt><dd>Paint over a face, a number plate or an address to hide it.</dd></div>
          <div><dt>Remove the background</dt><dd>Lift the main subject off its background. It runs on your device with Apple's Vision technology, so the photo is never uploaded.</dd></div>
          <div><dt>Frame and canvas</dt><dd>Add a border or change the canvas around the picture.</dd></div>
          <div><dt>Compare, undo and redo</dt><dd>Compare your edit with the original, step back through your edits, and step forward again.</dd></div>
          <div><dt>Save as JPG, PNG or HEIC</dt><dd>Choose the format that suits where the photo is going.</dd></div>
        </dl>
      </div>
    </div>
  </section>

  <section class="section band" id="tools" aria-labelledby="h-tools">
    <div class="wrap">
      <h2 id="h-tools">Seven tools for everything else</h2>
      <div class="section-body">
        <ul class="tools">
{tools_html}
        </ul>
      </div>
    </div>
  </section>

  <section class="section" id="private" aria-labelledby="h-private">
    <div class="wrap">
      <h2 id="h-private">Your photos never leave your device</h2>
      <div class="section-body">
        <p>Aperta has no account and no server that stores your pictures. Every edit, resize, compression and conversion runs on your phone. We do not run analytics of our own.</p>
        <ul class="checks">
          <li>You pick photos with the iOS photo picker, so Aperta sees only what you choose</li>
          <li>Saving to your library uses add-only permission</li>
          <li>Background removal runs on the device</li>
          <li>No account, no sign-in, no subscription</li>
        </ul>
        <p>The only outside service is the ad network. The <a href="privacy/">privacy policy</a> explains what it collects.</p>
      </div>
    </div>
  </section>

  <section class="section band" id="free" aria-labelledby="h-free">
    <div class="wrap">
      <h2 id="h-free">Free, and paid for by ads</h2>
      <div class="section-body">
        <p>Aperta has no subscription and no in-app purchase. Ads from Google AdMob pay for it, and they appear in two places.</p>
        <div class="split">
          <div>
            <h3>Where you will see ads</h3>
            <ul>
              <li>A banner on the Home screen.</li>
              <li>One short rewarded video before you save or share a finished photo. You choose whether to watch it, and one watched ad covers your exports for 2 minutes.</li>
            </ul>
          </div>
          <div>
            <h3>When no ad is available</h3>
            <ul>
              <li>The export goes ahead for free.</li>
              <li>This happens, for example, when you are offline.</li>
            </ul>
          </div>
        </div>
        <p>Where the law asks for it, the app shows a consent form from Google before personalised ads, and iOS may ask whether the app may track you. Aperta does not track you itself, and you can say no to the iOS prompt and still use everything. Settings has an Ad privacy choices row where one is required.</p>
      </div>
    </div>
  </section>

  <section class="section faq" id="faq" aria-labelledby="h-faq">
    <div class="wrap">
      <h2 id="h-faq">Questions</h2>
      <div class="section-body">
{faq_html}
      </div>
    </div>
  </section>
</main>
""" + footer("")
    (OUT / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- support
def build_support():
    title = "Support | Photo Editor & Collage: Aperta"
    desc = "Get help with Aperta: contact details, and answers about removing a background, removing location from a photo, ads, saving to Files and ID photo sizes."
    items = [
        ("How do I remove the background from a photo?",
         "<ol><li>Open a photo in the editor and choose Cutout.</li><li>Tap Remove background. Aperta finds the main subject on your device, so nothing is uploaded.</li><li>Choose what goes behind the subject, or keep it transparent.</li><li>Save. If you keep a transparent background, Aperta saves a PNG, because JPG cannot store transparency.</li></ol>"
         "<p>Cutout works best when the subject stands out from what is behind it. If the edge looks wrong, try a photo with clearer contrast between the subject and the background.</p>"),
        ("How do I remove the location from a photo?",
         "<p>Open the Photo details tool and choose the photo. It shows where and how the photo was taken. Turn on Remove location (and, if you like, the option to remove camera and device details), then save a copy. Your original photo is not changed, and the copy is the one to share.</p>"
         "<p>Do this before you send a photo to people you do not know. Anyone who has the original file can see where it was taken.</p>"),
        ("Why am I asked to watch an ad?",
         "<p>Aperta is free, and ads pay for it. Before you save or share a finished photo, the app offers one short video that you choose to watch. One watched ad covers your exports for 2 minutes. If you choose Not now, nothing is exported and you can try again any time. If no ad is available, for example when you are offline or your ad privacy choice does not allow ads, the export goes ahead without one. Editing never needs an ad.</p>"),
        ("How do I save a photo to the Files app?",
         "<p>When your photo is ready, tap the share button next to Save to Photos. In the share sheet, choose Save to Files, pick a folder and tap Save. Save to Photos adds the picture to your photo library instead.</p>"),
        ("Which ID and passport photo sizes does Aperta make?",
         "<p>The ID photo tool has sizes for these places, plus a custom size from 20 to 80 mm wide and 20 to 100 mm high:</p>"
         "<table><thead><tr><th>Size</th><th>Dimensions</th></tr></thead><tbody>"
         "<tr><td>United States</td><td>2 x 2 in</td></tr>"
         "<tr><td>EU and UK</td><td>35 x 45 mm</td></tr>"
         "<tr><td>Schengen visa</td><td>35 x 45 mm</td></tr>"
         "<tr><td>Japan</td><td>35 x 45 mm</td></tr>"
         "<tr><td>India</td><td>51 x 51 mm</td></tr>"
         "<tr><td>China</td><td>33 x 48 mm</td></tr>"
         "<tr><td>Canada</td><td>50 x 70 mm</td></tr></tbody></table>"
         "<p>You can save a single photo or a print sheet on 4 x 6 in, A4 or Letter paper, at 300 dpi. Rules change, so check the current requirements of the office that will receive your photo before you print.</p>"),
        ("I deleted the app and my edits are gone",
         "<p>Aperta keeps no library of your photos, so anything you did not save or export is gone with the app, and we cannot recover it. Your original photos stay in your photo library. A full backup of your device may still contain the app's data if you made one before deleting it.</p>"),
        ("I saw an ad that seems wrong",
         "<p>Write to us at the address above. Tell us roughly when and where in the app you saw it and what it showed. A screenshot helps. We block ad categories and advertisers through Google AdMob where we can.</p>"),
        ("I want to change my ad or tracking choice",
         "<p>Open Settings in the app and look for the Ad privacy choices row, which appears where the law requires it. You can also change tracking in iOS Settings under Privacy and Security, then Tracking, and reset your advertising identifier there.</p>"),
        ("I have an idea for a tool or a filter",
         "<p>Send it. We read every message, though we cannot promise to build every idea.</p>"),
    ]
    faq_html = "\n".join(f'          <details><summary>{html.escape(q)}</summary><div class="answer">{a}</div></details>' for q, a in items)
    body = head(title, desc, "support/", root="../") + header("../", "support") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <div class="doc">
        <h1>Support</h1>
        <p class="lede">Write to us and a person will read it.</p>
        <p class="contact-line">{EMAIL_TEXT}</p>
        <p class="small">Select the address to copy it into your mail app.</p>
        <p>We reply by email. A message gets answered faster when it includes:</p>
        <ul>
          <li>your iPhone model and iOS version</li>
          <li>what you were doing and what happened</li>
          <li>the tool you were using</li>
          <li>a screenshot, if it helps</li>
        </ul>
        <p>Aperta is not released yet, so support right now covers questions about the app before launch.</p>
        <h2>Common questions</h2>
        <div class="faq">
{faq_html}
        </div>
        <h2>Company</h2>
        <p>Ecom Swift LLC<br>30 N Gould St #37906<br>Sheridan, WY 82801<br>United States</p>
        <p>Read the <a href="../privacy/">privacy policy</a> and the <a href="../terms/">terms of use</a>.</p>
      </div>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / "support").mkdir(exist_ok=True)
    (OUT / "support" / "index.html").write_text(body, encoding="utf-8")


# ----------------------------------------------------------------------------- legal (markdown -> html)
URL_RE = re.compile(r"(https?://[^\s<)]+)")
MAIL_RE = re.compile(r"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})")


def inline(text):
    t = html.escape(text, quote=False)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)

    def url(m):
        u = m.group(1)
        trail = ""
        while u and u[-1] in ".,;":
            trail = u[-1] + trail
            u = u[:-1]
        return f'<a href="{u}" rel="noopener">{u}</a>{trail}'

    t = URL_RE.sub(url, t)
    # email addresses stay as selectable text (no mailto link)
    parts = re.split(r"(<a .*?</a>)", t)
    parts = [p if p.startswith("<a ") else MAIL_RE.sub(r'<span class="email">\1</span>', p) for p in parts]
    return "".join(parts)


def md_to_html(md):
    md = re.sub(r"<!-- DRAFT-NOTICE-START -->.*?<!-- DRAFT-NOTICE-END -->", "", md, flags=re.S)
    out, para, items = [], [], []
    title = ""
    meta_open = False
    seen_h2 = False

    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + "<br>".join(inline(p) for p in para) + "</p>")
            para = []

    def flush_list():
        nonlocal items
        if items:
            out.append("<ul>" + "".join(f"<li>{inline(i)}</li>" for i in items) + "</ul>")
            items = []

    for raw in md.splitlines():
        line = raw.rstrip()
        if line.startswith("# "):
            flush_para(); flush_list()
            title = line[2:].strip()
            out.append(f"<h1>{html.escape(title)}</h1>")
        elif line.startswith("## "):
            flush_para(); flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            seen_h2 = True
            out.append(f"<h2>{inline(line[3:].strip())}</h2>")
        elif line.startswith("- "):
            flush_para()
            items.append(line[2:].strip())
        elif not line.strip():
            flush_para(); flush_list()
        elif line.startswith("**") and title and not seen_h2:
            if not meta_open:
                out.append('<div class="meta">'); meta_open = True
            out.append("<p>" + inline(line) + "</p>")
        else:
            flush_list()
            if meta_open:
                out.append("</div>"); meta_open = False
            para.append(line.strip())
    flush_para(); flush_list()
    if meta_open:
        out.append("</div>")
    return title, "\n".join(out)


def build_legal(src, folder, current_title, desc):
    md = (LEGAL / src).read_text(encoding="utf-8")
    title, content = md_to_html(md)
    page_title = f"{current_title} | {SITE_NAME}"
    body = head(page_title, desc, folder + "/", root="../") + header("../", "") + f"""
<main id="main">
  <div class="page">
    <div class="wrap">
      <article class="doc">
{content}
      </article>
    </div>
  </div>
</main>
""" + footer("../")
    (OUT / folder).mkdir(exist_ok=True)
    (OUT / folder / "index.html").write_text(body, encoding="utf-8")


def build_misc():
    urls = ["", "support/", "privacy/", "terms/"]
    xml = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">']
    for u in urls:
        xml.append(f"  <url><loc>{BASE}{u}</loc><lastmod>{UPDATED}</lastmod></url>")
    xml.append("</urlset>")
    (OUT / "sitemap.xml").write_text("\n".join(xml) + "\n", encoding="utf-8")
    (OUT / "robots.txt").write_text(
        "# Hosted on GitHub Pages as a project path under /aperta/.\n"
        "User-agent: *\nAllow: /\n\n"
        f"Sitemap: {BASE}sitemap.xml\n", encoding="utf-8")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if OUT != SRC_SITE:  # review build elsewhere: bring the assets along
        shutil.copytree(SRC_SITE / "assets", OUT / "assets", dirs_exist_ok=True)
    build_index()
    build_support()
    build_legal("privacy-policy.md", "privacy", "Privacy Policy",
                "How Photo Editor & Collage: Aperta handles information: photos are processed on your device and never uploaded, there is no account, and ads come from Google AdMob with your consent where required.")
    build_legal("terms-of-use.md", "terms", "Terms of Use",
                "The terms for using Photo Editor & Collage: Aperta, a free photo editor supported by ads.")
    build_misc()
    print("site built in", OUT)


if __name__ == "__main__":
    main()
