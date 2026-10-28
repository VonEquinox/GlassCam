PY ?= uv run --no-project --python 3.12 --with-requirements tests/numeric/requirements.txt --with tifffile python -B
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

.PHONY: native test-native test-numeric
native:
	swift build -c release --package-path Packages/GlassCamKit --product GlassCamNative

test-native:
	python3 scripts/test_native.py

test-numeric:
	$(PY) -m pytest tests/numeric
