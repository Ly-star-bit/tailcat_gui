# Tailcat GUI top-level targets. Nothing here launches a GUI.
SHELL := /bin/bash
export PATH := /opt/homebrew/bin:$(PATH)

.PHONY: all core-test core-e2e core-cross macos android windows sync app-analyze app-test apk clean

all: core-test macos sync

core-test:
	cd core && go vet ./... && go test ./...

core-e2e:            ## uses Tailscale's public DERP relays
	cd core && TAILCAT_E2E=1 go test ./engine -run E2E -count=1 -timeout 300s -v

core-cross:          ## compile-check the engine for every target OS
	cd core && GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build ./engine/... \
	        && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build ./engine/... \
	        && GOOS=linux   GOARCH=amd64 CGO_ENABLED=0 go build ./engine/...

macos:
	bash build/build_macos.sh

android:
	bash build/build_android.sh

windows:
	bash build/build_windows.sh

sync:
	bash build/sync_libs.sh

app-analyze:
	cd app && flutter analyze --no-pub
	cd app/packages/tailcat_core_ffi && flutter analyze --no-pub

app-test:
	cd app && flutter test

apk: android sync    ## debug APK, build only (never runs the app)
	cd app && flutter build apk --debug --target-platform android-arm64

clean:
	rm -rf build/out
