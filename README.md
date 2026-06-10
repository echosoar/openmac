# openmac

Turn the various capabilities of the Mac system into APIs and Skills.

## Endpoints

- `POST /api/ocr` with JSON `{ "url": "..." }`, `{ "base64": "..." }`, or `{ "file": "/local/path" }`
- `GET /api/ocr?url=...`
- `POST /api/web-content` with JSON `{ "url": "...", "gotoOptions": { "waitUntil": "domcontentloaded|networkidle2|networkidle0", "timeout": 30000 } }`
- `GET /api/web-content?url=...&waitUntil=...&timeout=...`
- `timeout` is a non-negative millisecond value; `0` returns the current rendered HTML immediately
