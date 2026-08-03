#!/bin/sh
set -eu

repository_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
project_path="$repository_dir/CueMirror.xcodeproj"
output_dir="$repository_dir/dist"
derived_data="$output_dir/DerivedData"

mkdir -p "$output_dir"

xcodebuild \
  -project "$project_path" \
  -scheme CueMirror \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO \
  build

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$derived_data/Build/Products/Release/CueMirror.app/Contents/Info.plist")
artifact="$output_dir/CueMirror-$version-macOS-arm64.zip"

codesign --force --deep --sign - "$derived_data/Build/Products/Release/CueMirror.app"
ditto -c -k --keepParent "$derived_data/Build/Products/Release/CueMirror.app" "$artifact"
echo "$artifact"
