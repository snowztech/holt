APP := build/Holt.app
# Match LSMinimumSystemVersion, or the Rust library targets the build machine's macOS.
export MACOSX_DEPLOYMENT_TARGET := 14.0
# A stable signing identity keeps the Accessibility grant across rebuilds.
# Ad-hoc signing ("-") works too, but macOS forgets the grant on every build.
SIGN_ID ?= $(shell security find-identity -p codesigning -v | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')

.PHONY: core mac run test clean

core:
	cd core && cargo build --release
	rm -rf build/gen build/headers apple/HoltCoreFFI.xcframework
	cd core && cargo run -q --release --bin uniffi-bindgen -- generate \
		--library target/release/libholt_core.dylib --language swift --out-dir ../build/gen
	mkdir -p build/headers apple/Sources/HoltCore
	cp build/gen/holt_coreFFI.h build/headers/
	cp build/gen/holt_coreFFI.modulemap build/headers/module.modulemap
	xcodebuild -create-xcframework -library core/target/release/libholt_core.a \
		-headers build/headers -output apple/HoltCoreFFI.xcframework
	cp build/gen/holt_core.swift apple/Sources/HoltCore/

mac: core
	cd apple && swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp apple/.build/release/Holt $(APP)/Contents/MacOS/
	cp apple/Info.plist $(APP)/Contents/
	codesign --force --sign "$(or $(SIGN_ID),-)" $(APP)

run: mac
	-pkill -x Holt
	open $(APP)

test:
	cd core && cargo test

clean:
	rm -rf build apple/.build apple/HoltCoreFFI.xcframework apple/Sources/HoltCore/holt_core.swift
	cd core && cargo clean
