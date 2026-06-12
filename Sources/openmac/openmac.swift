#if os(macOS)
import SwiftUI

@main
struct OpenMacApp: App {
    var body: some Scene {
        WindowGroup {
            OpenMacView()
        }
        .windowResizability(.contentSize)
    }
}
#else
@main
struct openmac {
    static func main() {
        print("openmac requires macOS to run the SwiftUI app.")
    }
}
#endif
