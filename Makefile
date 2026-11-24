PROJECT := TVCompanion.xcodeproj
SCHEME  := TVCompanion
DERIVED := build
APP     := $(DERIVED)/Build/Products/Release/TVCompanion.app

.PHONY: project build run test install clean

project:
	xcodegen generate

build: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) build

run: build
	open $(APP)

test: project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED) test

install: build
	rm -rf ~/Applications/TVCompanion.app
	mkdir -p ~/Applications
	cp -R $(APP) ~/Applications/
	open ~/Applications/TVCompanion.app

clean:
	rm -rf $(DERIVED) $(PROJECT)
