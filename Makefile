PY ?= uv run --no-project --python 3.12 --with-requirements tests/numeric/requirements.txt --with tifffile python -B
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: native test-native test-numeric
native:
	swift build -c release --package-path Packages/GlassCamKit --product GlassCamNative

test-native:
	python3 scripts/test_native.py

test-numeric:
	$(PY) -m pytest tests/numeric

SIMULATOR_ID ?=
DIAGNOSTICS ?= $(HOME)/Library/Developer/GlassCamDiagnostics
SWIFT_BUILD = swift test -c release --package-path Packages/GlassCamKit --build-system native

.PHONY: test test-tools test-swift test-app test-baseline test-ui prepare-test-resources

test: test-tools test-native test-numeric test-swift test-app

test-tools:
	$(PY) -m pytest tests/tools

prepare-test-resources:
	bash scripts/prepare_ffcs_resources.sh vendor/ffcs/source.zip Packages/GlassCamKit/.build/test-resources/FFCS
	python3 scripts/prepare_lumix_resources.py --output Packages/GlassCamKit/.build/test-resources/LUMIX

test-swift: prepare-test-resources
	GLASSCAM_TEST_RESOURCES="$(CURDIR)/Packages/GlassCamKit/.build/test-resources" GLASSCAM_TEST_FIXTURES="$(CURDIR)/tests/fixtures" $(SWIFT_BUILD)

test-app:
	@simulator_id=$$(python3 scripts/select_simulator.py $(if $(SIMULATOR_ID),--id "$(SIMULATOR_ID)")) && \
	xcodebuild test -project App/GlassCam.xcodeproj -scheme GlassCamUnitTests -destination "platform=iOS Simulator,id=$$simulator_id" -parallel-testing-enabled NO -derivedDataPath "$(DIAGNOSTICS)/app-unit-tests" ONLY_ACTIVE_ARCH=YES

test-baseline: prepare-test-resources
	GLASSCAM_TEST_RESOURCES="$(CURDIR)/Packages/GlassCamKit/.build/test-resources" GLASSCAM_TEST_FIXTURES="$(CURDIR)/tests/fixtures" GLASSCAM_BASELINE_OUTPUT="$(DIAGNOSTICS)/color-baseline" $(SWIFT_BUILD) --filter 'BaselineTests|ColorChainTests'

test-ui:
	@simulator_id=$$(python3 scripts/select_simulator.py $(if $(SIMULATOR_ID),--id "$(SIMULATOR_ID)")) && \
	xcodebuild test -project App/GlassCam.xcodeproj -scheme GlassCamCaptureTests -destination "platform=iOS Simulator,id=$$simulator_id" -parallel-testing-enabled NO -derivedDataPath "$(DIAGNOSTICS)/ui-tests" ONLY_ACTIVE_ARCH=YES
