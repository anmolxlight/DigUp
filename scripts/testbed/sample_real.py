# Picks a random (seeded) sample of your own files by kind and clones them into <testbed>/real/.
# APFS clones (cp -c) share blocks with the originals, so the sample costs no disk space. On Linux there's no
# Spotlight: the folders are walked and files told apart by extension (screenshots by name or a Screenshots folder),
# ffprobe and pdfinfo stand in for mdls, and copies are reflinks where the file system has them.
#   python3 -I sample_real.py <testbed_dir>
import os, random, re, subprocess, sys

HOME = os.path.expanduser("~")
OUT = os.path.join(sys.argv[1], "real")
ROOTS = [f"{HOME}/{d}" for d in ("Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music")]
LINUX = sys.platform.startswith("linux")
if LINUX:
    ROOTS = [f"{HOME}/{d}" for d in ("Desktop", "Documents", "Downloads", "Pictures", "Videos", "Music")]
SKIP = re.compile(r"/(node_modules|\.git|\.venv|venv|site-packages|build|DerivedData|Pods)/|\.noindex/|\.photoslibrary/|\.app/|/\.[^/]+/|DigUpTestbed/")
rng = random.Random(7)


# The Spotlight queries below, by the kind each asks for, for Linux.
KINDS = [("kMDItemIsScreenCapture == 1", "screenshot"), ("com.adobe.pdf", "pdf"), ("wordprocessingml", "doc"),
         ("public.movie", "video"), ("public.audio", "audio"), ("public.image", "image")]
EXTENSIONS = {"image": {"jpg", "jpeg", "png", "heic", "webp", "gif", "tif", "tiff"}, "pdf": {"pdf"},
              "doc": {"docx", "doc", "rtf", "md", "txt"}, "video": {"mp4", "mov", "m4v", "mkv", "webm", "avi"},
              "audio": {"mp3", "m4a", "wav", "flac", "ogg", "opus", "aac"}}


def walk(kind):
    found = []
    for root in ROOTS:
        for folder, folders, files in os.walk(root):
            folders[:] = [f for f in folders if not f.startswith(".")]
            for name in files:
                path = os.path.join(folder, name)
                ext = name.rsplit(".", 1)[-1].lower()
                shot = name.startswith(("Screenshot", "Screen Shot")) or os.path.basename(folder).lower() == "screenshots"
                if SKIP.search(path) or name.startswith("."):
                    continue
                if kind == "screenshot" and ext in EXTENSIONS["image"] and shot:
                    found.append(path)
                elif kind == "image" and ext in EXTENSIONS["image"] and not shot:
                    size = probe(path, "stream=width,height")
                    if len(size) == 2 and min(size) >= 256:
                        found.append(path)
                elif kind in EXTENSIONS and kind != "image" and ext in EXTENSIONS[kind]:
                    found.append(path)
    return sorted(set(found))


def probe(path, entries):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", entries, "-of",
                          "csv=p=0:s=x", path], capture_output=True).stdout.decode("utf-8", "replace").strip()
    try:
        return [float(v) for v in out.split("\n")[0].split("x") if v]
    except ValueError:
        return []


def mdfind(query):
    if LINUX:
        return walk(next(kind for key, kind in KINDS if key in query))
    found = []
    for root in ROOTS:
        if os.path.isdir(root):
            out = subprocess.run(["mdfind", "-0", "-onlyin", root, query], capture_output=True).stdout
            found += [p for p in out.decode("utf-8", "replace").split("\0") if p and not SKIP.search(p)]
    return sorted(set(found))


def attr(path, name):
    if LINUX:
        if name == "kMDItemNumberOfPages":
            info = subprocess.run(["pdfinfo", path], capture_output=True).stdout.decode("utf-8", "replace")
            pages = [line.split()[-1] for line in info.splitlines() if line.startswith("Pages:")]
            return float(pages[0]) if pages else None
        out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                             capture_output=True).stdout.decode("utf-8", "replace").strip()
        try:
            return float(out)
        except ValueError:
            return None
    out = subprocess.run(["mdls", "-raw", "-name", name, path], capture_output=True).stdout.decode("utf-8", "replace").strip()
    try:
        return float(out)
    except ValueError:
        return None


def pick(paths, n, keep=lambda p: True):
    paths = paths[:]
    rng.shuffle(paths)
    chosen = []
    for p in paths:
        if len(chosen) == n:
            break
        if os.path.isfile(p) and keep(p):
            chosen.append(p)
    return chosen


def clone(paths, kind, manifest):
    dest_dir = os.path.join(OUT, kind)
    os.makedirs(dest_dir, exist_ok=True)
    for src in paths:
        name = os.path.basename(src)
        dst, i = os.path.join(dest_dir, name), 2
        while os.path.exists(dst):
            stem, ext = os.path.splitext(name)
            dst, i = os.path.join(dest_dir, f"{stem} {i}{ext}"), i + 1
        # -c clones (no extra space), -p keeps dates; cp copies xattrs (the screenshot flag) by default.
        if subprocess.run(["cp", "--reflink=auto" if LINUX else "-c", "-p", src, dst], capture_output=True).returncode == 0:
            manifest.append(f"{kind}\t{os.path.relpath(dst, OUT)}\t{src}")
        else:
            print(f"  skipped (clone failed): {name}", file=sys.stderr)


manifest = []
shots = mdfind("kMDItemIsScreenCapture == 1 && kMDItemContentTypeTree == 'public.image'")
clone(pick(shots, 120), "screenshots", manifest)

images = mdfind("kMDItemContentTypeTree == 'public.image' && kMDItemIsScreenCapture != 1 && kMDItemPixelWidth >= 256 && kMDItemPixelHeight >= 256")
clone(pick(images, 120), "images", manifest)

pdfs = mdfind("kMDItemContentTypeTree == 'com.adobe.pdf'")
big = pick(pdfs, 2, lambda p: (attr(p, "kMDItemNumberOfPages") or 0) > 100)
clone(big + pick([p for p in pdfs if p not in big], 23, lambda p: 0 < (attr(p, "kMDItemNumberOfPages") or 0) <= 100), "pdfs", manifest)

docs = mdfind("kMDItemContentTypeTree == 'org.openxmlformats.wordprocessingml.document' || kMDItemContentTypeTree == 'com.microsoft.word.doc' || kMDItemContentTypeTree == 'public.rtf' || kMDItemContentTypeTree == 'net.daringfireball.markdown' || (kMDItemContentTypeTree == 'public.plain-text' && kMDItemFSName == '*.txt'c)")
clone(pick(docs, 15), "docs", manifest)

videos = [p for p in mdfind("kMDItemContentTypeTree == 'public.movie'") if not p.lower().endswith((".ts", ".mts"))]
clone(pick(videos, 6, lambda p: 30 <= (attr(p, "kMDItemDurationSeconds") or 0) <= 900 and os.path.getsize(p) <= 600e6), "videos", manifest)

audio = mdfind("kMDItemContentTypeTree == 'public.audio'")
dur = lambda lo, hi: (lambda p: lo <= (attr(p, "kMDItemDurationSeconds") or 0) < hi)
a_short = pick(audio, 3, dur(5, 300))
a_mid = pick([p for p in audio if p not in a_short], 2, dur(300, 1200))
a_long = pick([p for p in audio if p not in a_short + a_mid], 1, dur(1800, 5400))
clone(a_short + a_mid + a_long, "audio", manifest)

with open(os.path.join(OUT, "MANIFEST.tsv"), "w") as f:
    f.write("kind\ttestbed path\tsource\n" + "\n".join(manifest) + "\n")
counts = {}
for line in manifest:
    counts[line.split("\t")[0]] = counts.get(line.split("\t")[0], 0) + 1
print("real/:", ", ".join(f"{v} {k}" for k, v in counts.items()))
