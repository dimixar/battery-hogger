#!/bin/bash

set -euo pipefail

readonly script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly project_directory="$(cd -- "$script_directory/.." && pwd)"

configuration="release"
signing_identity="auto"
output_directory="$project_directory/dist"

usage() {
    echo "Usage: scripts/build-app.sh [--debug|--release] [--identity IDENTITY|-] [--output DIRECTORY]"
    echo
    echo "  --identity auto   Use the first available Apple code-signing identity (default)."
    echo "  --identity -      Use ad-hoc signing; privileged registration may be rejected."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            configuration="debug"
            shift
            ;;
        --release)
            configuration="release"
            shift
            ;;
        --identity)
            [[ $# -ge 2 ]] || { usage >&2; exit 64; }
            signing_identity="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage >&2; exit 64; }
            output_directory="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

if [[ "$signing_identity" == "auto" ]]; then
    signing_identity="$({
        security find-identity -v -p codesigning 2>/dev/null \
            | sed -n 's/^[[:space:]]*[0-9][0-9]*).*"\([^"]*\)".*/\1/p' \
            | head -n 1
    } || true)"
    if [[ -z "$signing_identity" ]]; then
        signing_identity="-"
    fi
fi

readonly sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
readonly swift_compiler="$(xcrun --find swiftc)"
readonly app_identifier="com.molosnicdumitru.BatteryHogger"
readonly daemon_identifier="com.molosnicdumitru.BatteryHogger.Monitor"
readonly app_name="BatteryHogger"
readonly daemon_name="BatteryHoggerMonitor"

mkdir -p -- "$output_directory"
output_directory="$(cd -- "$output_directory" && pwd)"

if [[ "$output_directory" == "/" || -z "$output_directory" ]]; then
    echo "Refusing unsafe output directory: $output_directory" >&2
    exit 70
fi

readonly final_app="$output_directory/$app_name.app"
readonly final_zip="$output_directory/$app_name.zip"
readonly staging_directory="$(mktemp -d "$output_directory/.battery-hogger-build.XXXXXX")"
readonly staged_app="$staging_directory/$app_name.app"

cleanup() {
    rm -rf -- "$staging_directory"
}
trap cleanup EXIT

mkdir -p \
    "$staged_app/Contents/MacOS" \
    "$staged_app/Contents/Library/LaunchDaemons"

common_flags=(
    -sdk "$sdk_path"
    -target arm64-apple-macosx13.0
    -swift-version 6
    -strict-concurrency=complete
    -warnings-as-errors
)

if [[ "$configuration" == "release" ]]; then
    common_flags+=(-O -whole-module-optimization)
else
    common_flags+=(-Onone -g -D DEBUG)
fi

if [[ "$signing_identity" == "-" ]]; then
    common_flags+=(-D ADHOC_SIGNING)
fi

shared_sources=(
    "$project_directory/Shared/MonitorConstants.swift"
    "$project_directory/Shared/ProcessSnapshot.swift"
    "$project_directory/Shared/WorkloadSnapshot.swift"
    "$project_directory/Shared/MonitorSnapshot.swift"
    "$project_directory/Shared/MonitorXPCProtocol.swift"
)

daemon_sources=(
    "$project_directory/Daemon/CoalitionGPUEnergyReader.swift"
    "$project_directory/Daemon/PackageCPUEnergyReader.swift"
    "$project_directory/Daemon/ProcessSampler.swift"
    "$project_directory/Daemon/WorkloadDetector.swift"
    "$project_directory/Daemon/WorkloadAnalyzer.swift"
    "$project_directory/Daemon/MonitorEngine.swift"
    "$project_directory/Daemon/MonitorService.swift"
    "$project_directory/Daemon/main.swift"
)

app_sources=(
    "$project_directory/App/MonitorClient.swift"
    "$project_directory/App/MonitorModel.swift"
    "$project_directory/App/MenuContentView.swift"
    "$project_directory/App/BatteryHoggerApp.swift"
)

echo "Building $daemon_name ($configuration, arm64)..."
"$swift_compiler" \
    "${common_flags[@]}" \
    "${shared_sources[@]}" \
    "${daemon_sources[@]}" \
    -o "$staged_app/Contents/MacOS/$daemon_name"

echo "Building $app_name ($configuration, arm64)..."
"$swift_compiler" \
    "${common_flags[@]}" \
    -parse-as-library \
    "${shared_sources[@]}" \
    "${app_sources[@]}" \
    -o "$staged_app/Contents/MacOS/$app_name"

cp -- "$project_directory/Resources/BatteryHogger-Info.plist" "$staged_app/Contents/Info.plist"
cp -- \
    "$project_directory/Resources/com.molosnicdumitru.BatteryHogger.Monitor.plist" \
    "$staged_app/Contents/Library/LaunchDaemons/"

/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $app_name" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $app_identifier" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $app_name" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.0" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion en" "$staged_app/Contents/Info.plist"

echo "Signing embedded daemon with: $signing_identity"
codesign \
    --force \
    --sign "$signing_identity" \
    --identifier "$daemon_identifier" \
    --options runtime \
    --timestamp=none \
    "$staged_app/Contents/MacOS/$daemon_name"

echo "Signing application with: $signing_identity"
codesign \
    --force \
    --sign "$signing_identity" \
    --identifier "$app_identifier" \
    --options runtime \
    --timestamp=none \
    "$staged_app"

plutil -lint \
    "$staged_app/Contents/Info.plist" \
    "$staged_app/Contents/Library/LaunchDaemons/$daemon_identifier.plist"
codesign --verify --deep --strict --verbose=2 "$staged_app"

rm -rf -- "$final_app"
rm -f -- "$final_zip"
mv -- "$staged_app" "$final_app"
ditto -c -k --sequesterRsrc --keepParent "$final_app" "$final_zip"

echo
echo "Built: $final_app"
echo "Archive: $final_zip"
if [[ "$signing_identity" == "-" ]]; then
    echo "Warning: this build is ad-hoc signed; SMAppService may reject privileged registration."
fi
shasum -a 256 "$final_zip"
