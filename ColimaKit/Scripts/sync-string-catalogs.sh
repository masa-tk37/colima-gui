#!/bin/zsh
# Neither SwiftPM nor xcodebuild writes newly used keys back into a string catalog (only the Xcode IDE does).
set -euo pipefail

cd "${0:A:h}/.."
swift build

intermediates=.build/out/Intermediates.noindex/ColimaKit.build/Debug
for target in ColimaCore ColimaAdapters ColimaUI; do
  stringsdata=(${intermediates}/${target}-*.build/Objects-normal/*/*.stringsdata(N))
  if (( ${#stringsdata} == 0 )); then
    print -u2 "No .stringsdata found for ${target} under ${intermediates}"
    exit 1
  fi
  xcrun xcstringstool sync "Sources/${target}/Resources/Localizable.xcstrings" --stringsdata ${stringsdata}
done

cd ..
xcodebuild -project ColimaGUI.xcodeproj -scheme ColimaGUI -configuration Debug -quiet build
app_objects=$(xcodebuild -project ColimaGUI.xcodeproj -scheme ColimaGUI -configuration Debug -showBuildSettings \
  | awk '/ OBJECT_FILE_DIR_normal /{print $3}')
xcrun xcstringstool sync ColimaGUI/Localizable.xcstrings --stringsdata ${app_objects}/*/*.stringsdata
