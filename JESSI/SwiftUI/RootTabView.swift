import SwiftUI

struct RootTabView: View {
	@State private var selectedTab: Int = 1

	var body: some View {
		TabView(selection: $selectedTab) {
			NavigationView {
				ServerManagerView()
			}
			.navigationViewStyle(StackNavigationViewStyle())
			.tag(0)
			.tabItem {
				Label("Servers", systemImage: "folder")
			}

			NavigationView {
				LaunchView()
			}
			.navigationViewStyle(StackNavigationViewStyle())
			.tag(1)
			.tabItem {
				Label("Launch", systemImage: "play")
			}

			NavigationView {
				SettingsView()
			}
			.navigationViewStyle(StackNavigationViewStyle())
			.tag(2)
			.tabItem {
				Label("Settings", systemImage: "gear")
			}
		}
		.accentColor(.green)
	}
}
