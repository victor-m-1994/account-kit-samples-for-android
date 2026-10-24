import SwiftUI

@main
struct SubfloorMapperApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environment(store)
        }
    }
}
