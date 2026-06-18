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
- `POST /api/translate` with JSON `{ "text": "...", "from": "en", "to": "zh" }` (`from` optional, macOS 15+)
- `GET /api/translate?text=...&to=...&from=...`
- `POST /api/web-content` with JSON `{ "url": "...", "gotoOptions": { "waitUntil": "domcontentloaded|networkidle2|networkidle0", "timeout": 30000 } }`
- `GET /api/web-content?url=...&waitUntil=...&timeout=...`
- `timeout` is a non-negative millisecond value; `0` returns the current rendered HTML immediately
- `POST /api/face` with JSON `{ "url": "..." }`, `{ "base64": "..." }`, or `{ "file": "/local/path" }`
- `GET /api/face?url=...`
- Detects faces with Vision and returns, per face: `boundingBox` (normalized, origin bottom-left), pose angles `roll` / `yaw` / `pitch`, `landmarks` (named point groups in coordinates normalized to the face bounding box), and a `featureVector` (image feature print) usable for comparing faces
- `POST /api/qrcode` with JSON `{ "url": "..." }`, `{ "base64": "..." }`, or `{ "file": "/local/path" }`
- `GET /api/qrcode?url=...`
- Detects QR codes and barcodes and returns, per code: decoded `payload`, `symbology` (e.g. `VNBarcodeSymbologyQR`, `VNBarcodeSymbologyEAN13`), and `boundingBox`
- `POST /api/tts` with JSON `{ "text": "...", "language": "en-US", "voice": "...", "rate": 0.5, "pitch": 1.0, "volume": 1.0 }` (only `text` is required)
- `GET /api/tts?text=...&language=...&voice=...&rate=...&pitch=...&volume=...`
- Synthesizes speech and returns `{ "audio": "<base64 WAV>" }`
