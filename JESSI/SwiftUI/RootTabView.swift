import SwiftUI
import Combine

#if canImport(UIKit)
import UIKit

struct RootTabView: View {
    @StateObject private var tourManager = TourManager()
    private let minSwipeDistance: CGFloat = 60

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }

    var body: some View {
        let tabBinding = Binding<Int>(
            get: { tourManager.selectedTab },
            set: { newValue in
                if tourManager.isTourActive {
                    tourManager.selectedTab = tourManager.expectedTabForTourState
                } else {
                    tourManager.selectedTab = newValue
                }
            }
        )
        ZStack {
            TabView(selection: tabBinding) {
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
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { gesture in
                        if tourManager.isTourActive { return }
                        handleTabSwipe(gesture)
                    }
            )

            if tourManager.tourState == 0 {
                ZStack {
                    VisualEffectBlur(style: .systemMaterial)
                        .edgesIgnoringSafeArea(.all)

                    Color.black.opacity(0.20)
                        .edgesIgnoringSafeArea(.all)

                    WelcomeTourView()
                        .environmentObject(tourManager)
                }
            }
        }
        .accentColor(.green)
        .environmentObject(tourManager)
        .onAppear {
            keepalivemgr.shared.startifenabled()
            TunnelingModel.autoinstallplayitondemand()
        }
    }

    private func handleTabSwipe(_ gesture: DragGesture.Value) {
        let horizontalTranslation = gesture.translation.width
        let verticalTranslation = gesture.translation.height

        guard abs(horizontalTranslation) > abs(verticalTranslation) else {
            return
        }

        guard abs(horizontalTranslation) >= minSwipeDistance else {
            return
        }

        let isSwipeLeft = horizontalTranslation < 0
        let newTab: Int

        if isSwipeLeft {
            newTab = min(tourManager.selectedTab + 1, tourManager.maxTabIndex)
        } else {
            newTab = max(tourManager.selectedTab - 1, 0)
        }

        guard newTab != tourManager.selectedTab else {
            return
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            tourManager.selectedTab = newTab
        }
    }
}

class TourManager: ObservableObject {
    let maxTabIndex = 2
    private let tourStateKey = "tourState"

    @Published var tourState: Int {
        didSet {
            UserDefaults.standard.set(tourState, forKey: tourStateKey)
        }
    }
    
    @Published var selectedTab: Int = 1

    var isTourActive: Bool {
        tourState >= 2 && tourState <= 4
    }
    
    init() {
        if UserDefaults.standard.object(forKey: tourStateKey) == nil {
            self.tourState = 0
        } else {
            self.tourState = UserDefaults.standard.integer(forKey: tourStateKey)
        }
    }
    
    func startTour() {
        tourState = 2
        selectedTab = 2
    }
    
    func skipTour() {
        tourState = 5
    }
    
    var expectedTabForTourState: Int {
        switch tourState {
        case 2: return 2
        case 3: return 0
        case 4: return 1
        default: return selectedTab
        }
    }

    func nextStep() {
        if tourState == 2 {
            tourState = 3
            selectedTab = 0
        } else if tourState == 3 {
            tourState = 4
            selectedTab = 1
        } else if tourState == 4 {
            tourState = 5
        }
    }
}

struct WelcomeTourView: View {
    @EnvironmentObject var tourManager: TourManager

    private func appIconUIImage() -> UIImage? {
        let info = Bundle.main.infoDictionary
        let icons = info?["CFBundleIcons"] as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let files = primary?["CFBundleIconFiles"] as? [String]
        guard let iconName = files?.last else { return nil }
        return UIImage(named: iconName)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let icon = appIconUIImage() {
                    Image(uiImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    Image(systemName: "server.rack")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 84, height: 84)
                        .foregroundColor(.green)
                }
            }

            Text("Welcome to JESSI!")
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            Text("JESSI allows you to run Minecraft servers directly on device")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(spacing: 12) {
                Button(action: {
                    tourManager.startTour()
                }) {
                    Text("Take a Tour")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .foregroundColor(.white)
                .background(Color.green)
                .cornerRadius(14)
                .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
                
                Button(action: {
                    tourManager.skipTour()
                }) {
                    Text("Skip")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .foregroundColor(.green)
                .background(Color.clear)
            }
        }
        .padding(20)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(16)
        .shadow(radius: 10)
        .padding(24)
    }
}

private struct VisualEffectBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

#else

struct RootTabView: View {
    @StateObject private var tourManager = TourManager()

    var body: some View {
        Text("JESSI requires UIKit/iOS runtime")
            .environmentObject(tourManager)
    }
}

class TourManager: ObservableObject {
    let maxTabIndex = 2
    @Published var tourState: Int = 0
    @Published var selectedTab: Int = 1

    var isTourActive: Bool {
        tourState >= 2 && tourState <= 4
    }

    var expectedTabForTourState: Int {
        switch tourState {
        case 2: return 2
        case 3: return 0
        case 4: return 1
        default: return selectedTab
        }
    }

    func startTour() {
        tourState = 2
        selectedTab = 2
    }

    func skipTour() {
        tourState = 5
    }

    func nextStep() {
        if tourState == 2 {
            tourState = 3
            selectedTab = 0
        } else if tourState == 3 {
            tourState = 4
            selectedTab = 1
        } else if tourState == 4 {
            tourState = 5
        }
    }
}

#endif
