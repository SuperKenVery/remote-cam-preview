.PHONY: bootstrap check protocol-test ios-project ios-build android-test format

bootstrap: ios-project

check: protocol-test
	@if command -v xcodegen >/dev/null 2>&1; then $(MAKE) ios-project; fi
	@if [ -x android/gradlew ] && command -v java >/dev/null 2>&1; then cd android && ./gradlew test; fi

protocol-test:
	python3 -m unittest discover -s protocol/tests -t . -v

ios-project:
	cd ios && xcodegen generate

ios-build: ios-project
	xcodebuild -project ios/RemoteCamPreview.xcodeproj -scheme RemoteCamPreview -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

android-test:
	cd android && ./gradlew test

format:
	@if command -v swiftformat >/dev/null 2>&1; then swiftformat ios; fi
	@if command -v ktlint >/dev/null 2>&1; then ktlint --format 'android/**/*.kt'; fi
