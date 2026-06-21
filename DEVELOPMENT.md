
## Build

This repository is a standalone macOS app. Open the Xcode project directly:

```sh
open openmac.xcodeproj
```

Build from the command line on macOS:

```sh
xcodebuild -project openmac.xcodeproj -scheme openmac -configuration Debug CODE_SIGNING_ALLOWED=NO build
```
