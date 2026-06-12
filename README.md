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
