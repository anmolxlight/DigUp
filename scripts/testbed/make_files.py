# The testbed's generated files on Linux, where the Mac scripts use AppKit, WebKit and macOS's own pictures: the same
# names and the same content (texts, layouts, page topics), drawn with Pillow, laid out by Pango (pango-view) for
# PDFs, and joined with pypdf. Run through uv, which brings Pillow and pypdf:
#   uv run --no-project --with pillow --with pypdf python -I make_files.py <what> <out_dir>
#     pictures      Wikipedia photos in place of macOS's sample pictures (/Library/User Pictures), 768 px
#     screenshots   make_screenshots.swift's six app screenshots
#     docs          make_docs.swift's PDFs and notes
#     long          make_long.swift's 120-page logbook, long notes and numbers
#     lang          make_lang.swift's Bengali and Arabic notes, PDFs and screenshots (→ <out>/bn, <out>/ar)
import io, json, os, subprocess, sys, tempfile, urllib.request

from PIL import Image, ImageDraw, ImageFont
from pypdf import PdfReader, PdfWriter
from pypdf.generic import RectangleObject

WHAT, OUT = sys.argv[1], sys.argv[2]
os.makedirs(OUT, exist_ok=True)
FONTS = "/usr/share/fonts/truetype"


def font(size, bold=False, mono=False, language=None):
    if language == "bn":
        name = f"noto/NotoSansBengali-{'Bold' if bold else 'Regular'}.ttf"
    elif language == "ar":
        name = f"noto/NotoSansArabic-{'Bold' if bold else 'Regular'}.ttf"
    elif mono:
        name = f"dejavu/DejaVuSansMono{'-Bold' if bold else ''}.ttf"
    else:
        name = f"dejavu/DejaVuSans{'-Bold' if bold else ''}.ttf"
    return ImageFont.truetype(os.path.join(FONTS, name), size)


# MARK: Screenshots (AppKit draws from the bottom left; these take the Mac scripts' coordinates and flip them)

W, H = 1440, 900
RED, YELLOW, GREEN = (255, 59, 48), (255, 204, 0), (40, 205, 65)
SYS_RED, SYS_BLUE, SYS_PINK = (255, 59, 48), (0, 122, 255), (255, 45, 85)
SYS_GREEN, SYS_ORANGE, SYS_PURPLE = (52, 199, 89), (255, 149, 0), (175, 82, 222)
DARK_GRAY, SECONDARY = (85, 85, 85), (128, 128, 128)


class Shot:
    def __init__(self, bg, chrome, title, language=None):
        self.image = Image.new("RGB", (W, H), (92, 115, 158))
        self.draw = ImageDraw.Draw(self.image)
        self.language = language
        win = (80, 60, W - 160, H - 120)
        self.box(win, bg, 12)
        self.rect((win[0], win[1] + win[3] - 44, win[2], 44), chrome)
        for i, color in enumerate([RED, YELLOW, GREEN]):
            x, y = win[0] + 18 + i * 22, win[1] + win[3] - 29
            self.draw.ellipse([x, H - y - 13, x + 13, H - y], fill=color)
        self.win = win

    def flip(self, x, y, w, h):
        return [x, H - y - h, x + w, H - y]

    def rect(self, r, color):
        self.draw.rectangle(self.flip(*r), fill=color)

    def box(self, r, color, radius=8):
        self.draw.rounded_rectangle(self.flip(*r), radius=radius, fill=color)

    def text(self, s, x, y, size, color=(0, 0, 0), bold=False, mono=False):
        """At (x, y) as NSString.draw(at:) puts it: y is the bottom of the line."""
        f = font(size, bold, mono, self.language)
        top = H - y - int(size * 1.25)
        self.draw.text((x, top), s.replace("︎", ""), font=f, fill=color)

    def text_in(self, s, rect, size, color=(0, 0, 0), bold=False):
        """In a box as NSString.draw(in:) puts it: from the box's top, right-aligned for Arabic."""
        f = font(size, bold, language=self.language)
        x, y, w, h = rect
        top = H - y - h
        kwargs = {"direction": "rtl", "language": "ar"} if self.language == "ar" else {}
        if self.language == "ar":
            width = self.draw.textlength(s, font=f, **kwargs)
            self.draw.text((x + w - width, top), s, font=f, fill=color, **kwargs)
        else:
            self.draw.text((x, top), s, font=f, fill=color, **kwargs)

    def save(self, path):
        self.image.save(path)


def screenshots(out):
    white, light = (255, 255, 255), (237, 237, 237)

    def render(name, bg, chrome, title, body):
        shot = Shot(bg, chrome, title)
        win = shot.win
        shot.text(title, win[0] + win[2] / 2 - 180, win[1] + win[3] - 32, 15, SECONDARY, bold=True)
        r = (win[0] + 40, win[1] + 30, win[2] - 80, win[3] - 110)
        body(shot, r)
        shot.save(os.path.join(out, name + ".png"))

    def minx(r): return r[0]
    def maxy(r): return r[1] + r[3]

    def payment(s, r):
        s.text("Invoices", minx(r), maxy(r) - 40, 30, bold=True)
        s.box((minx(r), maxy(r) - 140, r[2], 80), (255, 230, 230))
        s.text("⚠  Payment failed: Your card was declined (card_declined)", minx(r) + 24, maxy(r) - 95, 22, SYS_RED, bold=True)
        s.text("Invoice INV-2041   ·   Acme Design Studio   ·   $249.00 USD   ·   Visa •••• 4242", minx(r), maxy(r) - 200, 18)
        s.text("Attempted Oct 3, 2026 9:41 AM — The customer's bank declined the charge. Ask for another payment method.",
               minx(r), maxy(r) - 240, 16, DARK_GRAY)
        s.box((minx(r), maxy(r) - 320, 200, 44), SYS_BLUE)
        s.text("Retry payment", minx(r) + 40, maxy(r) - 308, 17, white, bold=True)
    render("shot_payment_error", white, light, "dashboard.payments.example.com — Invoices", payment)

    def traceback(s, r):
        lines = ["$ python train.py --epochs 10", "Traceback (most recent call last):",
                 "  File \"/Users/me/project/train.py\", line 3, in <module>", "    import torch",
                 "ModuleNotFoundError: No module named 'torch'", "$ pip install torch",
                 "error: externally-managed-environment"]
        for i, line in enumerate(lines):
            color = SYS_RED if "Error" in line or "error" in line else (230, 230, 230)
            s.text(line, minx(r), maxy(r) - 30 - i * 34, 22, color, mono=True)
    render("shot_python_traceback", (26, 26, 26), (56, 56, 56), "zsh — 120×40", traceback)

    def flight(s, r):
        s.text("Booking confirmed ✈", minx(r), maxy(r) - 40, 30, bold=True)
        s.box((minx(r), maxy(r) - 300, r[2] * 0.7, 220), (237, 245, 255), 14)
        s.text("San Francisco (SFO)  →  Tokyo Haneda (HND)", minx(r) + 30, maxy(r) - 120, 26, bold=True)
        s.text("Flight NH 7   ·   Departs Fri, Nov 14 at 14:30   ·   Arrives Sat 18:55", minx(r) + 30, maxy(r) - 170, 19)
        s.text("Passenger: Alex Doe   ·   Seat 32A   ·   Gate 112   ·   Confirmation code: K7Q2LM", minx(r) + 30,
               maxy(r) - 210, 19)
        s.text("Check-in opens 24 hours before departure.", minx(r) + 30, maxy(r) - 260, 16, DARK_GRAY)
    render("shot_flight_booking", white, light, "Mail — Your booking is confirmed", flight)

    def chat(s, r):
        msgs = [("Sam", "Can we move the design review to Thursday? I'm out sick tomorrow."),
                ("Priya", "Sure, Thursday 3pm works for me. I'll update the calendar invite."),
                ("Sam", "Thanks! I'll also share the new onboarding mockups before the meeting.")]
        for i, (who, what) in enumerate(msgs):
            y = maxy(r) - 60 - i * 110
            s.box((minx(r), y - 6, 44, 44), [SYS_ORANGE, SYS_PURPLE, SYS_ORANGE][i], 22)
            s.text(who, minx(r) + 60, y + 18, 18, bold=True)
            s.text(what, minx(r) + 60, y - 12, 19)
    render("shot_chat_meeting", white, light, "#design-team", chat)

    def weather(s, r):
        s.text("London", minx(r), maxy(r) - 50, 40, bold=True)
        s.text("18° · Heavy rain ☂ · 90% chance of rain", minx(r), maxy(r) - 110, 28)
        for i, day in enumerate(["Mon 🌧 15°", "Tue 🌧 14°", "Wed ⛈ 13°", "Thu 🌦 16°", "Fri ☁ 17°"]):
            s.box((minx(r) + i * 220, maxy(r) - 300, 200, 140), (255, 255, 255), 16)
            s.text(day, minx(r) + 30 + i * 220, maxy(r) - 240, 24)
    render("shot_weather", (217, 230, 245), light, "Weather", weather)

    def code(s, r):
        lines = ["import Accelerate", "", "struct SearchIndex {", "    var vectors: [Float]", "    let dimension = 768", "",
                 "    func search(query: [Float], topK: Int) -> [Int] {",
                 "        // cosine similarity via matrix-vector product",
                 "        var scores = [Float](repeating: 0, count: vectors.count / dimension)",
                 "        cblas_sgemv(CblasRowMajor, CblasNoTrans, ...)",
                 "        return scores.indices.sorted { scores[$0] > scores[$1] }.prefix(topK).map { $0 }",
                 "    }", "}"]
        for i, line in enumerate(lines):
            color = SYS_GREEN if "//" in line else SYS_PINK if any(k in line for k in ("struct", "func", "import")) \
                else (230, 230, 230)
            s.text(line, minx(r), maxy(r) - 30 - i * 30, 19, color, mono=True)
    render("shot_swift_code", (31, 31, 31), (51, 51, 51), "SearchIndex.swift — Editor", code)


# MARK: PDFs (pango-view lays each page out, on US Letter; pypdf joins them)

def pdf(path, pages, language=None):
    """`pages`: (title or None, body) per page."""
    writer = PdfWriter()
    with tempfile.TemporaryDirectory() as scratch:
        for index, (title, body) in enumerate(pages):
            def esc(t): return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
            size = 13 if language is None else 15
            markup = (f"<span size='{22 if language is None else 24}pt' weight='bold'>{esc(title)}</span>\n\n"
                      if title else "") + f"<span size='{size}pt'>{esc(body)}</span>"
            source = os.path.join(scratch, f"{index}.txt")
            with open(source, "w") as f:
                f.write(markup)
            page = os.path.join(scratch, f"{index}.pdf")
            family = {"bn": "Noto Sans Bengali", "ar": "Noto Sans Arabic"}.get(language, "DejaVu Sans")
            arguments = ["pango-view", "--no-display", "--markup", f"--font={family} 13", "--width=492",
                         "--margin=60", "--line-spacing=1.3", f"--output={page}", source]
            if language == "ar":
                arguments[1:1] = ["--rtl", "--align=right", "--language=ar"]
            elif language == "bn":
                arguments[1:1] = ["--language=bn"]
            subprocess.run(arguments, check=True, capture_output=True)
            reader = PdfReader(page)
            p = reader.pages[0]
            # pango-view makes the page as tall as the text: extend it down to a letter page.
            top = float(p.mediabox.top)
            p.mediabox = RectangleObject([0, top - 792, 612, top])
            p.cropbox = p.mediabox
            writer.add_page(p)
    with open(path, "wb") as f:
        writer.write(f)


def docs(out):
    pdf(os.path.join(out, "Annual notes 2026.pdf"), [
        ("Quarterly business review", "Revenue grew 20% compared to last year, driven by strong sales in Europe and a new "
         "enterprise plan. Operating costs stayed flat, and the team hired four engineers. Next quarter we will focus on "
         "retention and on expanding the partner program in Japan."),
        ("Hiking trip to Mount Fuji", "We started the climb from the Yoshida trail at the fifth station before sunrise. The "
         "path was rocky and cold near the summit, but the view of the clouds below the crater was unforgettable. Pack warm "
         "gloves, a headlamp and enough water; the mountain huts sell instant noodles."),
        ("Sourdough bread recipe", "Feed the starter the night before. Mix 500 g flour, 350 g water and 100 g active starter, "
         "rest for an hour, then add 10 g salt. Stretch and fold four times, shape a boule, proof overnight in the fridge and "
         "bake in a Dutch oven at 250 °C."),
    ])
    # "Scanned" receipt: text in a picture, so the PDF has no text layer.
    receipt = Image.new("RGB", (900, 1200), (247, 247, 247))
    draw = ImageDraw.Draw(receipt)
    lines = ["BLUE BOTTLE COFFEE", "Hayes Valley, San Francisco", "", "Oat latte            5.50",
             "Almond croissant     4.75", "Cold brew            4.25", "", "TOTAL               14.50", "VISA **** 4242",
             "Thank you for visiting!"]
    for i, line in enumerate(lines):
        draw.text((120, 1200 - (1050 - i * 60) - 42), line, font=font(34, bold=i == 0, mono=True), fill=(0, 0, 0))
    page = Image.new("RGB", (612 * 2, 792 * 2), (255, 255, 255))
    page.paste(receipt.resize((532 * 2, 712 * 2)), (40 * 2, 40 * 2))
    page.save(os.path.join(out, "Scan 2026-09-14.pdf"), resolution=144)
    notes(out, [
        ("Groceries.txt", "Grocery list for the weekend: milk, eggs, bread, apples, coffee beans and dish soap."),
        ("Tokyo itinerary.md", "# Tokyo trip\n\nFlight to Tokyo Haneda on November 14. Hotel in Shinjuku for five nights. "
         "Day trip to Kamakura on Sunday to see the Great Buddha."),
        ("Meeting notes.rtf", "Design review moved to Thursday at 3pm because Sam was sick. Priya will update the calendar "
         "invite and Sam will share the onboarding mockups."),
        ("Vector search notes.docx", "Notes on implementing cosine similarity search over embedding vectors with Accelerate in "
         "Swift: normalize vectors, use cblas_sgemv, keep the top-k with a heap."),
    ])


def notes(out, items, language=None):
    """txt/md as written; rtf and docx through pandoc (what Cocoa's writers make on a Mac)."""
    for name, content in items:
        path = os.path.join(out, name)
        ext = os.path.splitext(name)[1]
        if ext in (".rtf", ".docx"):
            arguments = ["pandoc", "-f", "markdown", "-t", ext[1:], "-s", "-o", path]
            if language == "ar":
                arguments += ["-M", "dir=rtl", "-M", "lang=ar"]
            # Paragraphs as written: a line break inside one is a space, an empty line starts the next.
            subprocess.run(arguments, input=content.replace("#", "\\#").encode(), check=True)
        else:
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)


# MARK: Long files (make_long.swift: the same seeded choices, so the same pages)

class Picker:
    def __init__(self):
        self.seed = 20251009

    def pick(self, items):
        self.seed = (self.seed * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        return items[(self.seed >> 33) % len(items)]


def long(out):
    rng = Picker()
    pick = rng.pick
    ports = ["Falmouth", "Fowey", "Plymouth", "Salcombe", "Dartmouth", "Weymouth", "Poole", "Yarmouth", "Cherbourg",
             "St Peter Port", "Alderney", "Brixham", "Penzance", "Newlyn", "St Mary's"]
    winds = ["northwest 3", "west 4", "southwest 4 to 5", "south 3", "variable 2", "northeast 4", "west 5, gusting 6",
             "southwest 3"]
    seas = ["slight", "moderate", "smooth", "slight to moderate", "a long swell from the west"]
    weather = ["Sunny spells and good visibility.", "Overcast, with drizzle in the afternoon.",
               "Clear skies, cold in the evening.", "Showers passing through, rainbow at noon.",
               "Grey and still all morning, brighter later.", "High cloud and a halo around the sun."]
    days = ["Two reefs in the main until the wind eased, then full sail and a long beat to windward.",
            "Practised man-overboard drills with the fender twice; both recoveries under two minutes.",
            "Checked the rigging at the mast foot and tightened a loose shackle on the kicker.",
            "Long reach along the coast, logged a steady six knots most of the way.",
            "Motor-sailed the last hour to make the tide at the harbour entrance.",
            "Cleaned the bilge, topped up the water tanks and bought bread and fruit ashore.",
            "Took bearings on the lighthouse and the church spire to fix our position on the chart.",
            "Changed the genoa sheets and whipped the frayed ends with waxed twine.",
            "Quiet day at anchor: read, swam off the stern and cooked a curry for dinner."]

    def log_page(number):
        start = pick(ports)
        to = pick([p for p in ports if p != start])
        return (f"Day {number}. Left {start} at {pick(['06:10', '07:45', '08:30', '09:15', '10:40'])}, bound for {to}. "
                f"Wind {pick(winds)}, sea {pick(seas)}. {pick(weather)} {pick(days)} {pick(list(reversed(days)))} "
                f"Moored in {to} after {pick(['18', '23', '27', '31', '36', '42'])} miles. Barometer "
                f"{pick(['1012', '1016', '1019', '1021', '1008'])} "
                "and steady. Crew well; the night watch went to the skipper and the mate in two-hour turns.")

    standouts = {
        41: "Day 41. The engine overheated off Start Point and stopped. The raw-water impeller had lost all its vanes, so "
            "we sailed the last eight miles into Brixham under genoa alone and fitted the spare impeller on the pontoon. "
            "Ordered two more from the chandlery; never leave harbour without a spare again.",
        66: "Day 66. At sunset a pod of a dozen common dolphins came racing in from the south and rode our bow wave for "
            "twenty minutes, leaping clear of the water and rolling to look up at us. Nobody wanted to go below for "
            "dinner. The skipper said it was the best evening of the whole season.",
        88: "Day 88. Picked up visitors' mooring ball M-417 in the Helford river, paid the harbour master eighteen pounds "
            "and rowed ashore for supplies. Quiet creek, oak woods down to the water, an egret fishing on the mud.",
        100: "Day 100. Fog came down so thick off the Lizard that we could not see the bow from the cockpit. We slowed to "
             "three knots, sounded the horn every two minutes and steered by radar and the plotter while a tanker's "
             "foghorn boomed somewhere to starboard. It lifted only as we reached the harbour wall.",
    }
    # Swift evaluates `standouts[number] ?? logPage(number)` lazily: a standout page draws no random choices.
    pages = [(f"Sailing log 2025 · page {n}", standouts[n] if n in standouts else log_page(n)) for n in range(1, 121)]
    pdf(os.path.join(out, "Sailing log 2025.pdf"), [(None, f"{t}\n\n{b}") for t, b in pages])

    topics = ["the release checklist", "on-call handover", "the design review backlog", "hiring for the data team",
              "the customer survey results", "budget for the next quarter", "the support queue", "flaky tests in CI",
              "the onboarding guide", "the API deprecation plan", "laptop refresh", "the team offsite"]
    actions = ["Priya will draft a proposal by Friday.", "Sam takes the follow-up with finance.",
               "We agreed to revisit this in two weeks.", "Ana will write it up in the wiki.",
               "No decision yet; collect more data first.", "Ben volunteered to own it this sprint.",
               "Moved to the next planning meeting.", "Done, closing the ticket."]
    text, week, told = "# Team notes 2026\n\n", 1, False
    while len(text) < 150_000:
        text += f"## Week {week}\n\n"
        if not told and len(text) > 120_000:
            told = True
            text += ("The big news: we agreed to move the whole team to a new office in Lisbon next March. The rent is "
                     "lower, half of the team already lives in Portugal, and the building has room to grow. Marta will look "
                     "at schools for the families who relocate, and the company covers the moving costs.\n\n")
        for _ in range(6):
            text += (f"- On {pick(topics)}: {pick(['discussed', 'reviewed', 'went through', 'looked again at'])} where it "
                     f"stands. {pick(actions)} {pick(actions)}\n")
        text += "\n"
        week += 1
    with open(os.path.join(out, "Team notes 2026.md"), "w") as f:
        f.write(text)
    readings = "timestamp,sensor,value\n"
    for row in range(12_000):
        readings += f"{1_760_000_000 + row * 60} {row % 17} {row * 7919 % 100_003}\n"
        if row == 11_500:
            readings += "4815162342 0 0\n"
    with open(os.path.join(out, "sensor readings.txt"), "w") as f:
        f.write(readings)


# MARK: Bengali and Arabic (make_lang.swift's texts)

def lang(out):
    bn, ar = os.path.join(out, "bn"), os.path.join(out, "ar")
    os.makedirs(bn, exist_ok=True)
    os.makedirs(ar, exist_ok=True)
    notes(bn, [
        ("পরীক্ষার ফলাফল.txt", "এসএসসি পরীক্ষার ফলাফল প্রকাশিত হয়েছে। এ বছর পাসের হার ৮৩ শতাংশ, যা গত বছরের চেয়ে বেশি। ঢাকা বোর্ডে মেয়েরা "
         "ছেলেদের চেয়ে ভালো ফল করেছে। ফলাফল শিক্ষা বোর্ডের ওয়েবসাইটে এবং মোবাইলে এসএমএসের মাধ্যমে জানা যাবে।"),
        ("ইলিশ মাছের রেসিপি.md", "# সরিষা ইলিশ\n\nসরিষা ইলিশ রান্নার জন্য প্রথমে সরিষা বাটা, কাঁচা মরিচ, হলুদ আর লবণ দিয়ে ইলিশ মাছের টুকরোগুলো "
         "মাখিয়ে নিন। কড়াইয়ে সরিষার তেল গরম করে মাছগুলো দিন, ঢেকে দিয়ে কম আঁচে দশ মিনিট রান্না করুন। গরম ভাতের সঙ্গে পরিবেশন করুন।"),
        ("Sundarbans trip.docx", "সুন্দরবন ভ্রমণ\n\nখুলনা থেকে লঞ্চে করে আমরা তিন দিনের জন্য সুন্দরবনে গিয়েছিলাম। ম্যানগ্রোভ বনের খালে নৌকায় "
         "ঘুরে আমরা রয়েল বেঙ্গল টাইগারের পায়ের ছাপ দেখেছি। চিত্রা হরিণ, বানর আর একটি বড় কুমিরও চোখে পড়েছে। রাতে লঞ্চের ছাদে বসে তারা "
         "দেখা ছিল সবচেয়ে সুন্দর অভিজ্ঞতা।"),
    ], language="bn")
    pdf(os.path.join(bn, "বাড়ি ভাড়ার চুক্তি.pdf"), [
        ("বাড়ি ভাড়ার চুক্তিপত্র", "ধানমন্ডি ৭ নম্বর রোডের তিন বেডরুমের ফ্ল্যাটটি মাসিক ২৫,০০০ টাকা ভাড়ায় দেওয়া হলো। ভাড়াটিয়া দুই মাসের ভাড়া "
         "অগ্রিম জমা দেবেন। প্রতি মাসের পাঁচ তারিখের মধ্যে ভাড়া পরিশোধ করতে হবে। বিদ্যুৎ, পানি ও গ্যাস বিল ভাড়াটিয়া আলাদাভাবে দেবেন। "
         "চুক্তির মেয়াদ এক বছর, এবং বাড়ি ছাড়ার আগে অন্তত দুই মাস আগে বাড়িওয়ালাকে লিখিতভাবে জানাতে হবে। ফ্ল্যাটে কোনো স্থায়ী পরিবর্তন "
         "করতে হলে বাড়িওয়ালার অনুমতি লাগবে।"),
        ("প্রোগ্রামিং ক্লাসের নোট", "আজকের ক্লাসে আমরা পাইথনে লুপ আর ফাংশন শিখেছি। for লুপ দিয়ে একটি তালিকার প্রতিটি উপাদানের উপর কাজ করা "
         "যায়, আর while লুপ চলতে থাকে যতক্ষণ শর্তটি সত্য থাকে। ফাংশন তৈরি করতে def শব্দটি ব্যবহার করা হয়, এবং return দিয়ে ফলাফল "
         "ফেরত পাঠানো হয়। বাড়ির কাজ: একটি ফাংশন লিখুন যা একটি সংখ্যার ফ্যাক্টোরিয়াল বের করে, তারপর লুপ দিয়ে এক থেকে দশ পর্যন্ত সব "
         "সংখ্যার ফ্যাক্টোরিয়াল ছাপুন।"),
    ], language="bn")

    def screen(path, title, language, body):
        shot = Shot((255, 255, 255), (237, 237, 237), title, language)
        win = shot.win
        shot.text_in(title, (win[0] + 200, win[1] + win[3] - 38, win[2] - 400, 30), 15, SECONDARY)
        r = (win[0] + 60, win[1] + 40, win[2] - 120, win[3] - 130)
        body(shot, r)
        shot.save(path)

    def wallet(s, r):
        x, top, w = r[0], r[1] + r[3], r[2]
        s.text_in("টাকা পাঠান", (x, top - 60, 600, 60), 34, bold=True)
        s.box((x, top - 200, w, 110), (255, 230, 230), 10)
        s.text_in("⚠  লেনদেন ব্যর্থ হয়েছে: অপর্যাপ্ত ব্যালেন্স", (x + 30, top - 175, w - 60, 60), 30, SYS_RED, bold=True)
        s.text_in("পরিমাণ: ৳ ৫,০০০   ·   প্রাপক: ০১৭০০-০০০০০০   ·   সময়: সকাল ১০:১২", (x, top - 290, w, 50), 24)
        s.text_in("আপনার অ্যাকাউন্টে যথেষ্ট টাকা নেই। টাকা যোগ করে আবার চেষ্টা করুন।", (x, top - 350, w, 50), 22, DARK_GRAY)
        s.box((x, top - 450, 300, 60), SYS_PINK, 10)
        s.text_in("আবার চেষ্টা করুন", (x + 50, top - 440, 260, 44), 24, (255, 255, 255), bold=True)
    screen(os.path.join(bn, "wallet_failed_bn.png"), "মোবাইল ওয়ালেট — টাকা পাঠান", "bn", wallet)

    notes(ar, [
        ("وصفة الكبسة.txt", "الكبسة السعودية: اغسل الأرز البسمتي وانقعه في الماء لمدة نصف ساعة. في قدر كبير، اقلِ البصل حتى يذبل ثم "
         "أضف قطع الدجاج والطماطم والثوم وبهارات الكبسة. أضف الماء واترك الدجاج ينضج، ثم أضف الأرز واطبخه على نار هادئة. قدّمها مع "
         "اللوز المحمص والزبيب."),
        ("Meeting minutes.rtf", "محضر اجتماع فريق التطوير\n\nتقرر تأجيل إطلاق التطبيق إلى شهر ديسمبر بسبب مشاكل في نظام الدفع "
         "الإلكتروني. سيقوم فريق الخوادم بإصلاح الأخطاء قبل نهاية الشهر، وسيتم اختبار النسخة الجديدة مع مجموعة صغيرة من المستخدمين."),
        ("ملاحظة.md", "# مُلاحَظَة\n\nقَالَ مُحَمَّدٌ إِنَّ الْمَكْتَبَةَ الْعَامَّةَ تُغْلَقُ فِي السَّاعَةِ الثَّامِنَةِ مَسَاءً يَوْمَ الْخَمِيسِ، فَلَا تَتَأَخَّرْ فِي إِعَادَةِ الْكُتُبِ."),
    ], language="ar")
    pdf(os.path.join(ar, "تقرير.pdf"), [
        ("التقرير الربعي", "ارتفعت المبيعات بنسبة خمسة عشر بالمئة في الربع الثالث مقارنة بالعام الماضي، بفضل نمو قوي في أسواق الخليج "
         "وإطلاق خدمة الاشتراك الجديدة. بقيت التكاليف التشغيلية مستقرة، وانضم ثلاثة مهندسين جدد إلى الفريق. في الربع القادم سنركز على "
         "رضا العملاء وتوسيع شبكة الشركاء."),
        ("رحلة إلى البتراء", "زرنا مدينة البتراء الأثرية في جنوب الأردن. مشينا عبر السيق الضيق حتى ظهرت الخزنة المنحوتة في الصخر "
         "الوردي. صعدنا إلى الدير في الصباح الباكر لتجنب الحر، وتناولنا الغداء في قرية وادي موسى. أنصح بارتداء حذاء مريح وحمل الكثير "
         "من الماء."),
    ], language="ar")

    def payment(s, r):
        x, top, w = r[0], r[1] + r[3], r[2]
        s.text_in("إتمام الطلب", (x, top - 60, w, 60), 34, bold=True)
        s.box((x, top - 200, w, 110), (255, 230, 230), 10)
        s.text_in("فشلت عملية الدفع: البطاقة مرفوضة من البنك  ⚠", (x + 30, top - 175, w - 60, 60), 30, SYS_RED, bold=True)
        s.text_in("المبلغ: ٣٥٠ ريال   ·   رقم الطلب: ٤٨٢١٧   ·   بطاقة فيزا تنتهي بـ ٤٢٤٢", (x, top - 290, w, 50), 24)
        s.text_in("يرجى استخدام بطاقة أخرى أو المحاولة مرة أخرى لاحقاً.", (x, top - 350, w, 50), 22, DARK_GRAY)
        s.box((x + w - 300, top - 450, 300, 60), SYS_BLUE, 10)
        s.text_in("إعادة المحاولة", (x + w - 280, top - 440, 260, 44), 24, (255, 255, 255), bold=True)
    screen(os.path.join(ar, "payment_error_ar.png"), "متجر إلكتروني — الدفع", "ar", payment)


# MARK: Pictures (macOS's sample pictures aren't here: photos of the same subjects, from Wikipedia's articles)

PICTURES = {
    "Animals": {"Penguin": "Emperor penguin", "Zebra": "Plains zebra", "Eagle": "Bald eagle", "Owl": "Barn owl",
                "Parrot": "Scarlet macaw", "Cat": "Cat", "Dog": "Golden Retriever", "Butterfly": "Monarch butterfly"},
    "Flowers": {"Dandelion": "Taraxacum officinale", "Sunflower": "Common sunflower", "Yellow Daisy": "Rudbeckia hirta",
                "Lotus": "Nelumbo nucifera", "Poppy": "Papaver rhoeas", "Rose": "Rosa rubiginosa"},
    "Fun": {"Gingerbread Man": "Gingerbread man", "Medal": "Gold medal", "Ice Cream": "Ice cream cone",
            "Kite": "Kite"},
    "Instruments": {"Violin": "Violin", "Guitar": "Classical guitar", "Piano": "Grand piano", "Drum": "Snare drum",
                    "Trumpet": "Trumpet"},
    "Nature": {"Earth": "The Blue Marble", "Lightning": "Lightning", "Cactus": "Saguaro", "Leaf": "Leaf",
               "Zen": "Japanese rock garden", "Snowflake": "Snowflake"},
    "Sports": {"Target": "Target archery", "Basketball": "Basketball (ball)", "Soccer": "Ball (association football)",
               "Tennis": "Tennis ball", "Golf": "Golf ball"},
}


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "DigUp-testbed/1.0 (https://github.com/ARahim3/DigUp)"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read()


def pictures(out):
    for group, items in PICTURES.items():
        for name, article in items.items():
            path = os.path.join(out, f"{group}-{name}.jpg")
            if os.path.exists(path):
                continue
            try:
                summary = json.loads(fetch("https://en.wikipedia.org/api/rest_v1/page/summary/"
                                           + urllib.parse.quote(article.replace(" ", "_"))))
                image = summary.get("originalimage") or summary.get("thumbnail")
                source = image["source"]
                if not source.lower().endswith((".jpg", ".jpeg", ".png")):
                    source = summary["thumbnail"]["source"]
                picture = Image.open(io.BytesIO(fetch(source))).convert("RGB")
                picture.thumbnail((768, 768))
                picture.save(path, quality=90)
            except Exception as error:   # one missing picture leaves its queries without an answer, nothing more
                print(f"  {group}-{name}: {error}", file=sys.stderr)


import urllib.parse  # noqa: E402  (used by pictures)

{"screenshots": screenshots, "docs": docs, "long": long, "lang": lang, "pictures": pictures}[WHAT](OUT)
print("ok")
