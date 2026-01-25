TARGET := iphone:clang:latest:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = jessi
JAVA_DIR = Resources/java
SWIFT = 1
jessi_SWIFT_BRIDGING_HEADER = $(THEOS_PROJECT_DIR)/SwiftUI/Bridging.h

jessi_FILES = \
	main.m \
	JessiAppDelegate.m \
	JessiPaths.m \
	JessiSettings.m \
	\
	JessiServerSoftware.m \
	JessiServerService.m \
	JessiJavaRunner.m \
	SwiftUI/JessiJITCheck.m \
	SwiftUI/RootTabView.swift \
	SwiftUI/SwiftUIEntry.swift \
	SwiftUI/DoneToolbarTextField.swift \
	SwiftUI/LaunchView.swift \
	SwiftUI/SettingsView.swift \
	SwiftUI/CreateServerView.swift \
	SwiftUI/FileBrowserView.swift \

jessi_CFLAGS = -fobjc-arc
jessi_LDFLAGS = -lc++ -lSystem
jessi_BUNDLE_RESOURCES = $(JAVA_DIR)

include $(THEOS_MAKE_PATH)/application.mk

before-all::
	$(ECHO_NOTHING)if [ -f "jessi.png" ]; then \
		for f in Resources/AppIcon29x29.png Resources/AppIcon29x29@2x.png Resources/AppIcon29x29@3x.png \
			Resources/AppIcon40x40.png Resources/AppIcon40x40@2x.png Resources/AppIcon40x40@3x.png \
			Resources/AppIcon50x50.png Resources/AppIcon50x50@2x.png \
			Resources/AppIcon57x57.png Resources/AppIcon57x57@2x.png Resources/AppIcon57x57@3x.png \
			Resources/AppIcon60x60.png Resources/AppIcon60x60@2x.png Resources/AppIcon60x60@3x.png \
			Resources/AppIcon72x72.png Resources/AppIcon72x72@2x.png \
			Resources/AppIcon76x76.png Resources/AppIcon76x76@2x.png ; do \
			cp -f "jessi.png" "$$f"; \
		done; \
	fi$(ECHO_END)

.PHONY: ipa
ipa:
	$(ECHO_NOTHING)chmod +x scripts/package-ipa.sh$(ECHO_END)
	$(ECHO_NOTHING)scripts/package-ipa.sh --build$(ECHO_END)

before-install::
	$(ECHO_NOTHING)mkdir -p $(JAVA_DIR)$(ECHO_END)
	$(ECHO_NOTHING)if [ ! -f "$(JAVA_DIR)/bin/java" ]; then echo "Warning: Java runtime not bundled. Run 'make get-java' first."; fi$(ECHO_END)

get-java:
	$(ECHO_NOTHING)echo "Downloading Java runtimes for iOS..."$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p depends$(ECHO_END)
	$(ECHO_NOTHING)echo "Downloading Java 8..."$(ECHO_END)
	$(ECHO_NOTHING)cd depends && if [ ! -f "jre8-ios-aarch64.zip" ]; then curl -L -o jre8-ios-aarch64.zip 'https://crystall1ne.dev/cdn/amethyst-ios/jre8-ios-aarch64.zip'; fi$(ECHO_END)
	$(ECHO_NOTHING)echo "Downloading Java 17..."$(ECHO_END)
	$(ECHO_NOTHING)cd depends && if [ ! -f "jre17-ios-aarch64.zip" ]; then curl -L -o jre17-ios-aarch64.zip 'https://crystall1ne.dev/cdn/amethyst-ios/jre17-ios-aarch64.zip'; fi$(ECHO_END)
	$(ECHO_NOTHING)echo "Downloading Java 21..."$(ECHO_END)
	$(ECHO_NOTHING)cd depends && if [ ! -f "jre21-ios-aarch64.zip" ]; then curl -L -o jre21-ios-aarch64.zip 'https://crystall1ne.dev/cdn/amethyst-ios/jre21-ios-aarch64.zip'; fi$(ECHO_END)
	$(ECHO_NOTHING)echo "Extracting Java 8..."$(ECHO_END)
	$(ECHO_NOTHING)rm -rf $(JAVA_DIR) && mkdir -p $(JAVA_DIR)$(ECHO_END)
	$(ECHO_NOTHING)cd depends && unzip -q -o jre8-ios-aarch64.zip && tar -xf jre8-arm64-*.tar.xz -C ../$(JAVA_DIR) && mv ../$(JAVA_DIR)/*-openjdk/* ../$(JAVA_DIR)/ 2>/dev/null ; rmdir ../$(JAVA_DIR)/*-openjdk 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)echo "Extracting Java 17..."$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p Resources/java17$(ECHO_END)
	$(ECHO_NOTHING)cd depends && unzip -q -o jre17-ios-aarch64.zip && tar -xf jre17-arm64-*.tar.xz -C ../Resources/java17 && mv ../Resources/java17/*-openjdk/* ../Resources/java17/ 2>/dev/null ; rmdir ../Resources/java17/*-openjdk 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)echo "Extracting Java 21..."$(ECHO_END)
	$(ECHO_NOTHING)mkdir -p Resources/java21$(ECHO_END)
	$(ECHO_NOTHING)cd depends && unzip -q -o jre21-ios-aarch64.zip && tar -xf jre21-arm64-*.tar.xz -C ../Resources/java21 && mv ../Resources/java21/*-openjdk/* ../Resources/java21/ 2>/dev/null ; rmdir ../Resources/java21/*-openjdk 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)echo "All Java runtimes extracted successfully!"$(ECHO_END)
