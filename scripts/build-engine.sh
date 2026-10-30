#!/bin/bash
# Builds Engine/build/X3FuseEngine.xcframework for iOS devices and the
# simulator. Needs no Node. Set CARGO to choose the cargo binary; else the
# script uses ~/.cargo/bin/cargo, then cargo in PATH. Xcode build phases
# often have a short PATH, so the script adds the cargo directory to it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
engine="$root/Engine"
out="$engine/build/X3FuseEngine.xcframework"
profile="${X3F_ENGINE_PROFILE:-release}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}"

cargo="${CARGO:-}"
if [ -z "$cargo" ]; then
    if [ -x "$HOME/.cargo/bin/cargo" ]; then
        cargo="$HOME/.cargo/bin/cargo"
    else
        cargo="$(command -v cargo || true)"
    fi
fi
if [ -z "$cargo" ] || [ ! -x "$cargo" ]; then
    echo "error: cargo not found. Install Rust with rustup or set CARGO." >&2
    exit 1
fi
export PATH="$(dirname "$cargo"):$PATH"

# Xcode sets SDK variables for its own target. They break Rust builds for
# other targets, so remove them.
unset SDKROOT PLATFORM_NAME

targets=(aarch64-apple-ios aarch64-apple-ios-sim)
for target in "${targets[@]}"; do
    "$cargo" build --locked --manifest-path "$engine/Cargo.toml" \
        --target "$target" --profile "$profile" --lib
done

target_dir="${CARGO_TARGET_DIR:-$engine/target}"
staging="$engine/build/staging"
rm -rf "$staging" "$out"
mkdir -p "$staging/include"
cp "$engine/include/x3fuse_engine.h" "$engine/include/module.modulemap" "$staging/include/"

# Cargo writes the dev profile to "debug".
dir="$profile"
[ "$profile" = dev ] && dir=debug
args=()
for target in "${targets[@]}"; do
    args+=(-library "$target_dir/$target/$dir/libx3fuse_engine.a" -headers "$staging/include")
done
xcodebuild -create-xcframework "${args[@]}" -output "$out"
rm -rf "$staging"
echo "Built $out"
