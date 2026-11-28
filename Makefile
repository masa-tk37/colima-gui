PROJECT := ColimaGUI.xcodeproj
SCHEME := ColimaGUI
DERIVED_DATA := build/DerivedData
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(DERIVED_DATA)

.PHONY: build release test clean

build:
	$(XCODEBUILD) -configuration Debug build

release:
	$(XCODEBUILD) -configuration Release build
	@echo "Built: $(DERIVED_DATA)/Build/Products/Release/ColimaGUI.app"

test:
	cd ColimaKit && swift test

clean:
	$(XCODEBUILD) -configuration Debug clean
	$(XCODEBUILD) -configuration Release clean
	cd ColimaKit && swift package clean
