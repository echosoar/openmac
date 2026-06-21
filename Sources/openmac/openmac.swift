#if os(macOS)
import SwiftUI

@main
struct OpenMacApp: App {
    @StateObject private var model = OpenMacAppModel()

    var body: some Scene {
        WindowGroup {
            OpenMacView()
                .environmentObject(model)
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
