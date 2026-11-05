"""InstaIndir for Windows: paste a link, press Enter, the video lands in Downloads."""
import re
import threading
import tkinter as tk
from pathlib import Path
from tkinter import ttk
from urllib.parse import urlparse

import yt_dlp

DOWNLOADS = Path.home() / "Downloads"
RESERVED = {"p", "reel", "reels", "tv", "explore", "accounts", "direct", "stories"}
# Chrome's app-bound cookie encryption often blocks reading; try Firefox and Edge first.
BROWSERS = ["firefox", "edge", "chrome"]


def story_link(raw):
    """Profile link, story link, "@user" or "user" -> story link."""
    s = raw.strip().lstrip("@")
    if "instagram.com/" in s:
        parts = [p for p in urlparse(s if s.startswith("http") else "https://" + s).path.split("/") if p]
        if len(parts) >= 2 and parts[0] == "stories":
            user = parts[1]
        elif parts and parts[0] not in RESERVED:
            user = parts[0]
        else:
            return None
    else:
        user = s
    if not re.fullmatch(r"[A-Za-z0-9._]{1,30}", user):
        return None
    return f"https://www.instagram.com/stories/{user}/"


def download(link, is_story, report):
    attempts = [None] + BROWSERS
    if is_story:
        attempts = BROWSERS
    last_error = "Bilinmeyen hata"
    for browser in attempts:
        if browser:
            report(f"{browser} çerezleriyle deneniyor…")

        def hook(d):
            if d["status"] == "downloading":
                report(f"İndiriliyor {d.get('_percent_str', '').strip()}")

        opts = {
            "outtmpl": str(DOWNLOADS / "%(uploader,extractor)s_%(id)s.%(ext)s"),
            "format_sort": ["vcodec:h264", "acodec:aac"],
            "merge_output_format": "mp4",
            "noplaylist": not is_story,
            "progress_hooks": [hook],
            "quiet": True,
            "no_warnings": True,
        }
        if browser:
            opts["cookiesfrombrowser"] = (browser,)
        try:
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.download([link])
            return "Bitti → İndirilenler"
        except Exception as e:  # noqa: BLE001
            last_error = str(e).replace("ERROR: ", "")
            if is_story and "You need to log in to access this content" in last_error:
                return "Bu hesabın şu an aktif hikâyesi yok ya da Instagram hikâyeleri vermedi."
    return "Hata: " + last_error


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("İnsta İndir")
        self.geometry("560x360")
        frame = ttk.Frame(self, padding=12)
        frame.pack(fill="both", expand=True)

        self.entry = ttk.Entry(frame)
        self.entry.pack(fill="x")
        self.entry.bind("<Return>", lambda _: self.start(False))
        self.entry.focus()

        buttons = ttk.Frame(frame)
        buttons.pack(fill="x", pady=8)
        ttk.Button(buttons, text="İndir", command=lambda: self.start(False)).pack(side="left")
        ttk.Button(buttons, text="Hikâye indir", command=lambda: self.start(True)).pack(side="left", padx=6)

        self.log = tk.Listbox(frame)
        self.log.pack(fill="both", expand=True)

    def start(self, is_story):
        raw = self.entry.get().strip()
        if is_story:
            links = [story_link(raw)] if story_link(raw) else []
        else:
            links = [w for w in raw.split() if w.startswith(("http://", "https://"))]
        if not links:
            self.log.insert(0, "Geçerli link ya da kullanıcı adı yok.")
            return
        self.entry.delete(0, "end")
        for link in links:
            self.log.insert(0, link)
            threading.Thread(target=self.worker, args=(link, is_story), daemon=True).start()

    def worker(self, link, is_story):
        def report(msg):
            self.after(0, self.set_status, link, msg)

        report(download(link, is_story, report))

    def set_status(self, link, msg):
        for i in range(self.log.size()):
            if self.log.get(i).startswith(link):
                self.log.delete(i)
                self.log.insert(i, f"{link}  —  {msg}")
                return


if __name__ == "__main__":
    App().mainloop()
