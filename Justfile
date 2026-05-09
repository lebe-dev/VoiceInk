set shell := ["bash", "-cu"]

deps_dir := env_var('HOME') / "VoiceInk-Dependencies"
whisper_cpp_dir := deps_dir / "whisper.cpp"
framework_path := whisper_cpp_dir / "build-apple/whisper.xcframework"
local_derived_data := justfile_directory() / ".local-build"

# List available recipes
default:
    @just --list

# Full build pipeline (check + build) — default workflow
all: check build

# Build and launch the app
dev: build run

# Verify required CLI tools are installed
check:
    @echo "Checking prerequisites..."
    @command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
    @command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
    @command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
    @echo "Prerequisites OK"

# Alias for `check`
healthcheck: check

# Clone and build whisper.xcframework into ~/VoiceInk-Dependencies
whisper:
    @mkdir -p "{{deps_dir}}"
    @if [ ! -d "{{framework_path}}" ]; then \
        echo "Building whisper.xcframework in {{deps_dir}}..."; \
        if [ ! -d "{{whisper_cpp_dir}}" ]; then \
            git clone https://github.com/ggerganov/whisper.cpp.git "{{whisper_cpp_dir}}"; \
        else \
            (cd "{{whisper_cpp_dir}}" && git pull); \
        fi; \
        cd "{{whisper_cpp_dir}}" && ./build-xcframework.sh; \
    else \
        echo "whisper.xcframework already built in {{deps_dir}}, skipping build"; \
    fi

# Ensure whisper framework is ready
setup: whisper
    @echo "Whisper framework is ready at {{framework_path}}"
    @echo "Please ensure your Xcode project references the framework from this location."

# Build Debug configuration (requires Apple Developer cert)
build: setup
    xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Build unsigned for local use (no Apple Developer account needed)
local: check setup
    @echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
    @rm -rf "{{local_derived_data}}"
    xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
        -derivedDataPath "{{local_derived_data}}" \
        -xcconfig LocalBuild.xcconfig \
        CODE_SIGN_IDENTITY="-" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=YES \
        DEVELOPMENT_TEAM="" \
        CODE_SIGN_ENTITLEMENTS={{justfile_directory()}}/VoiceInk/VoiceInk.local.entitlements \
        SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' \
        build
    @APP_PATH="{{local_derived_data}}/Build/Products/Debug/VoiceInk.app" && \
    if [ -d "$APP_PATH" ]; then \
        echo "Copying VoiceInk.app to ~/Downloads..."; \
        rm -rf "$HOME/Downloads/VoiceInk.app"; \
        ditto "$APP_PATH" "$HOME/Downloads/VoiceInk.app"; \
        xattr -cr "$HOME/Downloads/VoiceInk.app"; \
        echo ""; \
        echo "Build complete! App saved to: ~/Downloads/VoiceInk.app"; \
        echo "Run with: open ~/Downloads/VoiceInk.app"; \
        echo ""; \
        echo "Limitations of local builds:"; \
        echo "  - No iCloud dictionary sync"; \
        echo "  - No automatic updates (pull new code and rebuild to update)"; \
    else \
        echo "Error: Could not find built VoiceInk.app at $APP_PATH"; \
        exit 1; \
    fi

# Launch the already-built app
run:
    @if [ -d "$HOME/Downloads/VoiceInk.app" ]; then \
        echo "Opening ~/Downloads/VoiceInk.app..."; \
        open "$HOME/Downloads/VoiceInk.app"; \
    else \
        echo "Looking for VoiceInk.app in DerivedData..."; \
        APP_PATH=$(find "$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
        if [ -n "$APP_PATH" ]; then \
            echo "Found app at: $APP_PATH"; \
            open "$APP_PATH"; \
        else \
            echo "VoiceInk.app not found. Please run 'just build' or 'just local' first."; \
            exit 1; \
        fi; \
    fi

# Run the test suite via xcodebuild
test:
    xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS'

# Run a focused test (e.g. `just test-one VoiceInkTests/SomeTest/testCase`)
test-one TARGET:
    xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS' -only-testing:{{TARGET}}

# Remove all build artifacts and the ~/VoiceInk-Dependencies directory
clean:
    @echo "Cleaning build artifacts..."
    @rm -rf "{{deps_dir}}"
    @rm -rf "{{local_derived_data}}"
    @echo "Clean complete"
