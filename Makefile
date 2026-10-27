APP := build/Holt.app
# Match LSMinimumSystemVersion, or the Rust library targets the build machine's macOS.
export MACOSX_DEPLOYMENT_TARGET := 14.0
# A stable signing identity keeps the Accessibility grant across rebuilds.
# Ad-hoc signing ("-") works too, but macOS forgets the grant on every build.
SIGN_ID ?= $(shell security find-identity -p codesigning -v | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')

.PHONY: core core-ios bindings mac ios testflight icon run alfred test lint fmt dist clean

# The Mac slice only, so Mac work stays fast. `make core-ios` adds iPhone and Simulator.
core:
	cd core && cargo build --release
	$(MAKE) bindings XCFRAMEWORK_LIBS="-library core/target/release/libholt_core.a -headers build/headers"

core-ios:
	cd core && cargo build --release
	cd core && IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --lib --target aarch64-apple-ios
	cd core && IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --lib --target aarch64-apple-ios-sim
	$(MAKE) bindings XCFRAMEWORK_LIBS="\
		-library core/target/release/libholt_core.a -headers build/headers \
		-library core/target/aarch64-apple-ios/release/libholt_core.a -headers build/headers \
		-library core/target/aarch64-apple-ios-sim/release/libholt_core.a -headers build/headers"

# Generates the Swift bindings and packages the core as apple/HoltCoreFFI.xcframework.
bindings:
	rm -rf build/gen build/headers apple/HoltCoreFFI.xcframework
	cd core && cargo run -q --release --bin uniffi-bindgen -- generate \
		--library target/release/libholt_core.dylib --language swift --out-dir ../build/gen
	mkdir -p build/headers apple/Sources/HoltCore
	cp build/gen/holt_coreFFI.h build/headers/
	cp build/gen/holt_coreFFI.modulemap build/headers/module.modulemap
	xcodebuild -create-xcframework $(XCFRAMEWORK_LIBS) -output apple/HoltCoreFFI.xcframework
	cp build/gen/holt_core.swift apple/Sources/HoltCore/

mac: core
	cd apple && swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp apple/.build/release/Holt $(APP)/Contents/MacOS/
	# Sparkle installs updates. Its XPC services are only for sandboxed apps, which Holt isn't.
	mkdir -p $(APP)/Contents/Frameworks
	ditto apple/.build/release/Sparkle.framework $(APP)/Contents/Frameworks/Sparkle.framework
	rm -rf $(APP)/Contents/Frameworks/Sparkle.framework/XPCServices $(APP)/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices
	install_name_tool -add_rpath @executable_path/../Frameworks $(APP)/Contents/MacOS/Holt
	cp apple/Info.plist $(APP)/Contents/
	mkdir -p $(APP)/Contents/Resources
	cp apple/AppIcon.icns $(APP)/Contents/Resources/
	codesign --force --sign "$(or $(SIGN_ID),-)" $(APP)

# Redraws apple/AppIcon.icns from the Skip drawing in Brand.swift. Commit the result.
icon:
	cd apple && swift build -c release
	mkdir -p build/AppIcon.iconset
	apple/.build/release/Holt --render-icon build/icon-1024.png
	for s in 16 32 128 256 512; do \
		sips -z $$s $$s build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}.png >/dev/null; \
		sips -z $$((s * 2)) $$((s * 2)) build/icon-1024.png --out build/AppIcon.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/AppIcon.iconset -o apple/AppIcon.icns
	apple/.build/release/Holt --render-phone-icon apple/ios/Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png

# The iPhone app in the Simulator. Open apple/ios/Holt.xcodeproj in Xcode to run it on a phone.
ios: core-ios
	cd apple/ios && xcodegen generate --quiet
	xcodebuild -project apple/ios/Holt.xcodeproj -scheme Holt -destination 'generic/platform=iOS Simulator' \
		-derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO -quiet build

# Archive the iPhone app and upload it to TestFlight. Reads the API key from the environment.
testflight:
	scripts/testflight.sh

run: mac
	-pkill -x Holt
	open $(APP)

# build/Holt.alfredworkflow, the Alfred workflow. Opening the file installs it in Alfred.
alfred:
	rm -rf build/alfred && mkdir -p build/alfred
	cp alfred/info.plist alfred/search.sh build/alfred/
	cp raycast/assets/extension-icon.png build/alfred/icon.png
	rm -f build/Holt.alfredworkflow
	cd build/alfred && zip -qr ../Holt.alfredworkflow .

test:
	cd core && cargo test
	alfred/test.sh

SWIFT_SOURCES := apple/Sources/Holt apple/ios/Sources apple/Package.swift

lint:
	cd core && cargo fmt --check && cargo clippy --all-targets -- -D warnings
	swift format lint --strict -r $(SWIFT_SOURCES)

fmt:
	cd core && cargo fmt
	swift format -i -r $(SWIFT_SOURCES)

clean:
	rm -rf build apple/.build apple/HoltCoreFFI.xcframework apple/Sources/HoltCore/holt_core.swift
	cd core && cargo clean

# Signed, notarized build/Holt-<version>.dmg. See scripts/dist.sh.
dist:
	scripts/dist.sh
