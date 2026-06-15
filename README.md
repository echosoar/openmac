# openmac

Turn the various capabilities of the Mac system into APIs and Skills.

## Build

This repository is a standalone macOS app. Open the Xcode project directly:

```sh
open openmac.xcodeproj
```

Build from the command line on macOS:

```sh
xcodebuild -project openmac.xcodeproj -scheme openmac -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## Endpoints

- `POST /api/ocr` with JSON `{ "url": "..." }`, `{ "base64": "..." }`, or `{ "file": "/local/path" }`
- `GET /api/ocr?url=...`
- `POST /api/web-content` with JSON `{ "url": "...", "gotoOptions": { "waitUntil": "domcontentloaded|networkidle2|networkidle0", "timeout": 30000 } }`
- `GET /api/web-content?url=...&waitUntil=...&timeout=...`
- `timeout` is a non-negative millisecond value; `0` returns the current rendered HTML immediately
- `POST /api/search` with JSON `{ "text": "search text", "engines": ["bing", "brave"], "count": 3, "excludeDomains": ["baidu.com"] }`
- `GET /api/search?text=...&engines=bing,brave&count=3&excludeDomains=baidu.com,zhihu.com`
  - `text` (required) is the search query
  - `engines` (optional) is the list of search engines to query; defaults to `bing,baidu,brave`. Supported: `baidu`, `bing`, `brave`, `duckduckgo`, `google`, `sogou`, `wikipedia`, `arxiv`
  - `count` (optional) is the number of results per engine; defaults to `3`, capped at `6`
  - `excludeDomains` (optional) is a list of domains to filter out of the results; defaults to empty
  - For `GET`, `engines` and `excludeDomains` are comma-separated. Each engine is scraped in a headless WebView and runs concurrently; engines that fail or time out are omitted from the response
