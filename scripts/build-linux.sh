#!/bin/sh
# Builds fully static Linux binaries of umbra-server (x86_64 and aarch64) into dist/.
# They run on any distribution (Ubuntu, Arch, Debian, ...) with nothing else installed.
#
# Needs, once: the swift.org toolchain and the matching Static Linux SDK (versions must match):
#   https://www.swift.org/install/macos/  ->  installs into ~/Library/Developer/Toolchains
#   swift sdk install <swift-X.Y.Z-RELEASE_static-linux-*.artifactbundle.tar.gz>
set -eu
VERSION="${SWIFT_VERSION:-6.4.1}"
SWIFT="$HOME/Library/Developer/Toolchains/swift-$VERSION-RELEASE.xctoolchain/usr/bin/swift"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/dist"
cd "$ROOT/UmbraKit"
for arch in x86_64 aarch64; do
    "$SWIFT" build -c release --product umbra-server --swift-sdk "$arch-swift-linux-musl" \
        --scratch-path .build-linux -Xswiftc -static-stdlib -Xswiftc -gnone -Xlinker -s
    cp ".build-linux/out/Products/Release-staticlinux-$arch/umbra-server" "$ROOT/dist/umbra-server-linux-$arch"
done
cd "$ROOT/dist" && shasum -a 256 umbra-server-linux-* > SHA256SUMS && cat SHA256SUMS
