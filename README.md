# InstaIndir

Minimal macOS app: paste a link, press Enter, the video lands in Downloads. Optional transcript via whisper.

Works with Instagram (posts, reels, stories) and any site supported by [yt-dlp](https://github.com/yt-dlp/yt-dlp) (YouTube, TikTok, X, Vimeo, Reddit…).

## Requirements

- macOS 14+
- [Homebrew](https://brew.sh): `brew install yt-dlp ffmpeg whisper-cpp`
- Optional (transcripts): place `ggml-large-v3-turbo.bin` in `~/Library/Application Support/InstaIndir/`

## Build

```sh
./build.sh
open build/InstaIndir.app
```

## Notes

- Stories require login: the app reads your existing Chrome or Safari cookies locally via yt-dlp. Nothing is sent anywhere else.
- Videos are saved as H.264 + AAC so they open in QuickTime.

## Windows

A separate Python version lives in `windows/` (download + story download; no transcripts).

- **Download:** grab `InstaIndir.exe` from [Releases](../../releases). Install [ffmpeg](https://www.gyan.dev/ffmpeg/builds/) and add it to `PATH` for merged video + audio.
- **Run from source:** `pip install -r windows/requirements.txt` then `python windows/insta_indir.py`
- Stories: log in to Instagram in Firefox or Edge. Chrome's cookie encryption often blocks reading.
- The `.exe` is built by GitHub Actions (`.github/workflows/windows.yml`) on every `v*` tag.

## Disclaimer

For personal use only. Respect content owners' rights and each platform's terms of service. This project is not affiliated with Instagram or Meta.

## License

MIT
