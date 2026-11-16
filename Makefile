# --disable-sandbox 关 SwiftPM 自身（manifest 求值）的沙箱；
# -Xswiftc -disable-sandbox 关编译器的沙箱。两者都需要，受限环境/CI 下才不会
# 出现 "sandbox-exec: sandbox_apply: Operation not permitted"。
SANDBOX   := --disable-sandbox -Xswiftc -disable-sandbox
TESTPLUGIN := -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
OBSPLUGIN := -load-plugin-library /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libObservationMacros.dylib

.PHONY: build test release-test perf check-model check-ui app doctor clean

build:
	swift build $(SANDBOX)

test:
	swift test $(SANDBOX) $(TESTPLUGIN)

release-test:
	swift test -c release $(SANDBOX) $(TESTPLUGIN)

perf:
	swift test -c release $(SANDBOX) $(TESTPLUGIN) --filter 性能测量

check-model:
	@echo "typecheck HuaXingUI (all model files)..."
	swiftc -typecheck -swift-version 6 -default-isolation MainActor -target arm64-apple-macos27.0 \
		-I .build/out/Products/Debug \
		-I .build/checkouts/swift-subprocess/Sources/_SubprocessCShims/include \
		$(OBSPLUGIN) \
		App/Sources/HuaXingUI/*.swift 2>&1

check-ui:
	@# 三步探针：先 arm64，再 arm64e
	swiftc -typecheck -swift-version 6 -target arm64-apple-macos27.0 \
		-load-plugin-library /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libObservationMacros.dylib \
		App/Probe.swift 2>&1 || \
	swiftc -typecheck -swift-version 6 -target arm64e-apple-macos27.0 \
		-load-plugin-library /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/libObservationMacros.dylib \
		App/Probe.swift

app:
	./build-app.sh

doctor:
	swift run $(SANDBOX) huaxingctl doctor

clean:
	swift package clean
