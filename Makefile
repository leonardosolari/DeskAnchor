SHELL := /bin/bash
.DEFAULT_GOAL := build

.PHONY: all build run test release clean

all: build

build:
	bash scripts/build-app.sh

run: build
	open build/DeskAnchor.app

test:
	bash scripts/test.sh

# Same packaging command locally and on GitHub Actions. No certificate is required.
release:
	CODE_SIGN_IDENTITY="$${CODE_SIGN_IDENTITY:--}" UNIVERSAL=1 CONFIGURATION=release bash scripts/build-app.sh
	bash scripts/package-release.sh

clean:
	rm -rf -- .build build dist
