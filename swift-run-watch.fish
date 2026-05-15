#!/usr/bin/env fish

if test -z "$ROOT_DIR"
    set -gx ROOT_DIR (pwd)
end
if test -z "$DEVELOPER_DIR"
    set -gx DEVELOPER_DIR /System/Volumes/Data/Applications/Xcode.app/Contents/Developer
end

set -g SCRIPT_NAME (basename (status filename))
if test -z "$TARGET_NAME"
    set -g TARGET_NAME ""
end
if test -z "$SCHEME_NAME"
    set -g SCHEME_NAME ""
end
if test -z "$CONFIGURATION"
    set -g CONFIGURATION Debug
end
if test -z "$BUILD_DIR"
    set -g BUILD_DIR "$ROOT_DIR/build"
end
if test -z "$APP_LOG_PATH"
    set -g APP_LOG_PATH "$BUILD_DIR/"(path change-extension "" "$SCRIPT_NAME")".dev.log"
end
if test -z "$BUILD_LOG_PATH"
    set -g BUILD_LOG_PATH "$BUILD_DIR/"(path change-extension "" "$SCRIPT_NAME")".xcodebuild.log"
end
if test -z "$WATCH_INTERVAL"
    set -g WATCH_INTERVAL 1
end
if test -z "$PROJECT_FILE"
    set -g PROJECT_FILE ""
end
if test -z "$RUN_ONCE"
    set -g RUN_ONCE 0
end

set -g PROJECT_KIND ""
set -g PROJECT_OPTION ""
set -g PACKAGE_DIR ""
set -g BUILD_SETTINGS_CACHE
set -g PACKAGE_DUMP_CACHE

function errln
    printf '%s\n' $argv >&2
end

function normalize_path
    set -l path_value "$argv[1]"
    if string match -qr '^/' -- "$path_value"
        printf '%s\n' "$path_value"
    else
        printf '%s/%s\n' "$ROOT_DIR" "$path_value"
    end
end

function resolve_swiftpm_configuration
    switch "$CONFIGURATION"
        case Debug debug
            printf 'debug\n'
        case Release release
            printf 'release\n'
        case '*'
            printf '%s\n' "$CONFIGURATION" | tr '[:upper:]' '[:lower:]'
    end
end

function print_matches
    for path_value in $argv
        printf '  %s\n' "$path_value" >&2
    end
end

function set_project_context
    set -l project_path "$argv[1]"
    switch "$project_path"
        case '*.xcworkspace'
            set -g PROJECT_KIND xcode
            set -g PROJECT_OPTION -workspace
            set -g PACKAGE_DIR ""
        case '*.xcodeproj'
            set -g PROJECT_KIND xcode
            set -g PROJECT_OPTION -project
            set -g PACKAGE_DIR ""
        case '*/Package.swift' 'Package.swift'
            set -g PROJECT_KIND swiftpm
            set -g PROJECT_OPTION ""
            set -g PACKAGE_DIR (dirname "$project_path")
        case '*'
            errln "Unsupported project file: $project_path"
            return 1
    end
end

function collect_named_xcode_projects
    set -l root "$argv[1]"
    set -l name "$argv[2]"
    begin
        fd -HI -a -t d -g "$name.xcworkspace" "$root" --exclude .git --exclude build --exclude DerivedData --exclude .build
        fd -HI -a -t d -g "$name.xcodeproj" "$root" --exclude .git --exclude build --exclude DerivedData --exclude .build
    end
end

function collect_all_xcode_projects
    set -l root "$argv[1]"
    begin
        fd -HI -a -t d -g '*.xcworkspace' "$root" --exclude .git --exclude build --exclude DerivedData --exclude .build
        fd -HI -a -t d -g '*.xcodeproj' "$root" --exclude .git --exclude build --exclude DerivedData --exclude .build
    end
end

function collect_package_specs
    set -l root "$argv[1]"
    fd -HI -a -t f -g 'Package.swift' "$root" --exclude .git --exclude build --exclude DerivedData --exclude .build
end

function collect_project_specs
    set -l root "$argv[1]"
    fd -HI -a -t f -g 'project.yml' "$root" --exclude .git --exclude build --exclude DerivedData --exclude .build
end

function resolve_project_file
    if test -n "$PROJECT_FILE"
        set -l explicit_project (normalize_path "$PROJECT_FILE")
        if not test -e "$explicit_project"
            errln "Missing project file: $explicit_project"
            return 1
        end
        set_project_context "$explicit_project"; or return 1
        set -g PROJECT_FILE "$explicit_project"
        return 0
    end

    set -l search_root "$ROOT_DIR"
    set -l project_spec ""
    set -l matches

    if test -n "$TARGET_NAME"
        set matches (collect_named_xcode_projects "$search_root" "$TARGET_NAME")
        if test (count $matches) -eq 1
            set_project_context "$matches[1]"; or return 1
            set -g PROJECT_FILE "$matches[1]"
            return 0
        end
        if test (count $matches) -gt 1
            errln "Multiple project files found for target $TARGET_NAME:"
            print_matches $matches
            return 1
        end
    end

    set matches (collect_all_xcode_projects "$search_root")
    if test (count $matches) -eq 1
        set_project_context "$matches[1]"; or return 1
        set -g PROJECT_FILE "$matches[1]"
        return 0
    end
    if test (count $matches) -gt 1
        errln "Multiple project files found under $search_root:"
        print_matches $matches
        return 1
    end

    set matches (collect_package_specs "$search_root")
    if test (count $matches) -eq 1
        set_project_context "$matches[1]"; or return 1
        set -g PROJECT_FILE "$matches[1]"
        return 0
    end
    if test (count $matches) -gt 1
        errln "Multiple Package.swift files found under $search_root:"
        print_matches $matches
        return 1
    end

    set matches (collect_project_specs "$search_root")
    if test (count $matches) -eq 1
        set project_spec "$matches[1]"
        xcodegen generate --spec "$project_spec"; or return 1
        set search_root (dirname "$project_spec")
        if test -n "$TARGET_NAME"
            set matches (collect_named_xcode_projects "$search_root" "$TARGET_NAME")
        else
            set matches (collect_all_xcode_projects "$search_root")
        end
        if test (count $matches) -eq 1
            set_project_context "$matches[1]"; or return 1
            set -g PROJECT_FILE "$matches[1]"
            return 0
        end
        if test (count $matches) -gt 1
            errln "Multiple project files found after xcodegen:"
            print_matches $matches
            return 1
        end
        errln "Missing project file after xcodegen: $project_spec"
        return 1
    end
    if test (count $matches) -gt 1
        errln "Multiple project.yml files found under $search_root:"
        print_matches $matches
        return 1
    end

    errln "Missing project file under $search_root. Set PROJECT_FILE."
    return 1
end

function refresh_package_dump
    set -g PACKAGE_DUMP_CACHE (begin
        cd "$PACKAGE_DIR"
        env DEVELOPER_DIR="$DEVELOPER_DIR" swift package dump-package 2>/dev/null
    end)
end

function package_name_exists
    set -l name "$argv[1]"
    if test -z "$name"
        return 1
    end
    if test (count $PACKAGE_DUMP_CACHE) -eq 0
        refresh_package_dump; or return 1
    end
    printf '%s\n' $PACKAGE_DUMP_CACHE | jq -e --arg name "$name" '
      [
        ((.products // [])[]? | select(.type.executable != null) | .name),
        ((.targets // [])[]? | select(.type == "executable") | .name)
      ] | index($name) != null
    ' >/dev/null 2>&1
end

function scheme_exists
    set -l scheme "$argv[1]"
    if test -z "$scheme"
        return 1
    end
    if test "$PROJECT_KIND" = swiftpm
        package_name_exists "$scheme"
        return $status
    end

    xcodebuild $PROJECT_OPTION "$PROJECT_FILE" -scheme "$scheme" -configuration "$CONFIGURATION" -showBuildSettings >/dev/null 2>&1
end

function resolve_scheme_name
    if scheme_exists "$SCHEME_NAME"
        printf '%s\n' "$SCHEME_NAME"
        return 0
    end

    if test -n "$TARGET_NAME"
        if scheme_exists "$TARGET_NAME"
            printf '%s\n' "$TARGET_NAME"
            return 0
        end
    end

    if test "$PROJECT_KIND" = swiftpm
        if test (count $PACKAGE_DUMP_CACHE) -eq 0
            refresh_package_dump; or return 1
        end
        set -l fallback_name (printf '%s\n' $PACKAGE_DUMP_CACHE | jq -r '
          [
            ((.products // [])[]? | select(.type.executable != null) | .name),
            ((.targets // [])[]? | select(.type == "executable") | .name)
          ] | unique | .[0] // empty
        ')
        set -l name_count (printf '%s\n' $PACKAGE_DUMP_CACHE | jq -r '
          [
            ((.products // [])[]? | select(.type.executable != null) | .name),
            ((.targets // [])[]? | select(.type == "executable") | .name)
          ] | unique | length
        ')
        if test "$name_count" = 1 -a -n "$fallback_name"
            printf '%s\n' "$fallback_name"
            return 0
        end
        errln 'Missing executable product. Set SCHEME_NAME or TARGET_NAME.'
        return 1
    end

    set -l schemes_json (xcodebuild $PROJECT_OPTION "$PROJECT_FILE" -list -json 2>/dev/null; or true)
    set -l fallback_scheme (printf '%s\n' $schemes_json | jq -r '(.workspace.schemes // .project.schemes // [])[0] // empty')
    set -l scheme_count (printf '%s\n' $schemes_json | jq -r '(.workspace.schemes // .project.schemes // []) | length')
    if test "$scheme_count" = 1 -a -n "$fallback_scheme"
        printf '%s\n' "$fallback_scheme"
        return 0
    end

    errln 'Missing scheme. Set SCHEME_NAME or TARGET_NAME.'
    return 1
end

function generate_project
    resolve_project_file; or return 1
    set -g SCHEME_NAME (resolve_scheme_name); or return 1
end

function fetch_build_settings
    xcodebuild $PROJECT_OPTION "$PROJECT_FILE" -scheme "$SCHEME_NAME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null
end

function refresh_build_settings
    set -g BUILD_SETTINGS_CACHE (fetch_build_settings)
end

function read_build_setting
    set -l key "$argv[1]"
    for line in $BUILD_SETTINGS_CACHE
        if string match -q "*$key = *" -- "$line"
            printf '%s\n' (string replace -r '^.*= ' '' -- "$line")
            return 0
        end
    end
    return 1
end

function resolve_app_bundle
    if test "$PROJECT_KIND" = swiftpm
        printf '%s/%s.app\n' "$BUILD_DIR" "$SCHEME_NAME"
        return 0
    end

    set -l build_dir (read_build_setting TARGET_BUILD_DIR); or return 1
    set -l full_product_name (read_build_setting FULL_PRODUCT_NAME); or return 1
    printf '%s/%s\n' "$build_dir" "$full_product_name"
end

function resolve_swiftpm_binary_path
    set -l build_config (resolve_swiftpm_configuration)
    set -l candidates (fd -HI -a -t f -g "$SCHEME_NAME" "$PACKAGE_DIR/.build" | rg "/$build_config/$SCHEME_NAME\$")
    for candidate in $candidates
        if test -x "$candidate"
            printf '%s\n' "$candidate"
            return 0
        end
    end
    return 1
end

function find_unique_package_file
    set -l pattern "$argv[1]"
    set -l label "$argv[2]"
    if test -f "$PACKAGE_DIR/$pattern"
        printf '%s\n' "$PACKAGE_DIR/$pattern"
        return 0
    end

    set -l matches (fd -HI -a -t f -g "$pattern" "$PACKAGE_DIR" --exclude .git --exclude build --exclude DerivedData --exclude .build)
    if test (count $matches) -eq 0
        return 1
    end
    if test (count $matches) -eq 1
        printf '%s\n' "$matches[1]"
        return 0
    end

    errln "Multiple $label files found under $PACKAGE_DIR:"
    print_matches $matches
    return 2
end

function write_default_info_plist
    set -l plist_path "$argv[1]"
    set -l icon_stem "$argv[2]"
    begin
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'
        printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">'
        printf '%s\n' '<plist version="1.0">'
        printf '%s\n' '<dict>'
        printf '%s\n' '  <key>CFBundleDevelopmentRegion</key>'
        printf '%s\n' '  <string>en</string>'
        printf '%s\n' '  <key>CFBundleDisplayName</key>'
        printf '%s\n' "  <string>$SCHEME_NAME</string>"
        printf '%s\n' '  <key>CFBundleExecutable</key>'
        printf '%s\n' "  <string>$SCHEME_NAME</string>"
        if test -n "$icon_stem"
            printf '%s\n' '  <key>CFBundleIconFile</key>'
            printf '%s\n' "  <string>$icon_stem</string>"
        end
        printf '%s\n' '  <key>CFBundleIdentifier</key>'
        printf '%s\n' "  <string>local.$SCHEME_NAME</string>"
        printf '%s\n' '  <key>CFBundleInfoDictionaryVersion</key>'
        printf '%s\n' '  <string>6.0</string>'
        printf '%s\n' '  <key>CFBundleName</key>'
        printf '%s\n' "  <string>$SCHEME_NAME</string>"
        printf '%s\n' '  <key>CFBundlePackageType</key>'
        printf '%s\n' '  <string>APPL</string>'
        printf '%s\n' '  <key>CFBundleShortVersionString</key>'
        printf '%s\n' '  <string>1.0</string>'
        printf '%s\n' '  <key>CFBundleVersion</key>'
        printf '%s\n' '  <string>1</string>'
        printf '%s\n' '  <key>NSHighResolutionCapable</key>'
        printf '%s\n' '  <true/>'
        printf '%s\n' '</dict>'
        printf '%s\n' '</plist>'
    end > "$plist_path"
end

function package_swiftpm_app
    set -l app_bin (resolve_swiftpm_binary_path); or return 1
    set -l app_bundle (resolve_app_bundle); or return 1
    set -l plist_template ""
    set -l icon_path ""

    set plist_template (find_unique_package_file 'Info.plist' 'Info.plist')
    set -l cmd_status $status
    if test $cmd_status -gt 1
        return 1
    end

    set icon_path (find_unique_package_file 'AppIcon.icns' 'AppIcon.icns')
    set cmd_status $status
    if test $cmd_status -gt 1
        return 1
    end

    set -l macos_dir "$app_bundle/Contents/MacOS"
    set -l resources_dir "$app_bundle/Contents/Resources"
    set -l plist_target "$app_bundle/Contents/Info.plist"

    rm -rf "$app_bundle"
    mkdir -p "$macos_dir" "$resources_dir"
    cp "$app_bin" "$macos_dir/$SCHEME_NAME"
    chmod +x "$macos_dir/$SCHEME_NAME"

    set -l icon_stem ""
    if test -n "$icon_path"
        set -l icon_name (basename "$icon_path")
        set icon_stem (path change-extension "" "$icon_name")
        cp "$icon_path" "$resources_dir/$icon_name"
    end

    if test -n "$plist_template"
        cp "$plist_template" "$plist_target"
    else
        write_default_info_plist "$plist_target" "$icon_stem"
    end
end

function resolve_app_binary
    if test "$PROJECT_KIND" = swiftpm
        set -l app_bundle (resolve_app_bundle); or return 1
        if not test -d "$app_bundle"
            return 1
        end
        printf '%s/Contents/MacOS/%s\n' "$app_bundle" "$SCHEME_NAME"
        return 0
    end

    set -l build_dir (read_build_setting TARGET_BUILD_DIR); or return 1
    set -l executable_path (read_build_setting EXECUTABLE_PATH); or return 1
    printf '%s/%s\n' "$build_dir" "$executable_path"
end

function resolve_process_name
    if test "$PROJECT_KIND" = swiftpm
        printf '%s\n' "$SCHEME_NAME"
        return 0
    end
    read_build_setting EXECUTABLE_NAME
end

function build_app
    printf '\n==> Building %s (%s)\n' "$SCHEME_NAME" "$CONFIGURATION"
    if test "$PROJECT_KIND" = swiftpm
        env DEVELOPER_DIR="$DEVELOPER_DIR" swift build --package-path "$PACKAGE_DIR" -c (resolve_swiftpm_configuration) --product "$SCHEME_NAME" | tee "$BUILD_LOG_PATH"
        set -l cmd_status $pipestatus[1]
        if test $cmd_status -ne 0
            errln 'Build failed. Keep current app.'
            return 1
        end
        package_swiftpm_app; or return 1
        return 0
    end

    xcodebuild $PROJECT_OPTION "$PROJECT_FILE" -scheme "$SCHEME_NAME" -configuration "$CONFIGURATION" build | tee "$BUILD_LOG_PATH"
    set -l cmd_status $pipestatus[1]
    if test $cmd_status -ne 0
        errln 'Build failed. Keep current app.'
        return 1
    end
end

function restart_app
    if test "$PROJECT_KIND" = xcode
        refresh_build_settings; or return 1
    end

    set -l app_bundle (resolve_app_bundle); or return 1
    set -l app_bin (resolve_app_binary); or return 1
    set -l process_name (resolve_process_name)

    if not test -x "$app_bin"
        errln "Missing built app binary: $app_bin"
        return 1
    end

    set -l artifact_link ""
    if test "$PROJECT_KIND" = swiftpm
        set artifact_link "$app_bundle"
    else
        set artifact_link "$BUILD_DIR/"(basename "$app_bin")
        ln -sfn "$app_bin" "$artifact_link"
    end

    if test -n "$process_name"
        pkill -x "$process_name" >/dev/null 2>&1
        sleep 0.2
    end

    if test "$PROJECT_KIND" = swiftpm
        open "$app_bundle"
    else
        nohup "$app_bin" >"$APP_LOG_PATH" 2>&1 </dev/null &
    end

    printf 'Root: %s\n' "$ROOT_DIR"
    if test "$PROJECT_KIND" = swiftpm
        printf 'Package: %s\n' "$PROJECT_FILE"
        printf 'Launched app: %s\n' "$app_bundle"
    else
        printf 'Container: %s\n' "$PROJECT_FILE"
        printf 'Launched app: %s\n' "$app_bundle"
    end
    printf 'Scheme: %s\n' "$SCHEME_NAME"
    printf 'Shortcut: %s\n' "$artifact_link"
    if test "$PROJECT_KIND" = xcode
        printf 'App log: %s\n' "$APP_LOG_PATH"
    end
    printf 'Build log: %s\n' "$BUILD_LOG_PATH"
end

function list_watch_files
    if git -C "$ROOT_DIR" rev-parse --show-toplevel >/dev/null 2>&1
        begin
            cd "$ROOT_DIR"
            git ls-files -co --exclude-standard --deduplicate
        end
        return 0
    end

    begin
        cd "$ROOT_DIR"
        fd -HI -t f --exclude .git --exclude build --exclude DerivedData --exclude .build .
    end
end

function watch_fingerprint
    begin
        for rel_path in (list_watch_files | env LC_ALL=C sort)
            if test -f "$ROOT_DIR/$rel_path"
                stat -f '%m %N' "$ROOT_DIR/$rel_path"
            end
        end
    end | shasum -a 1 | awk '{print $1}'
end

mkdir -p "$BUILD_DIR"

generate_project; or exit 1
build_app; or exit 1
restart_app; or exit 1

if test "$RUN_ONCE" = 1
    exit 0
end

set -l last_fingerprint (watch_fingerprint)
printf 'Watching for changes under: %s\n' "$ROOT_DIR"

while true
    sleep "$WATCH_INTERVAL"
    set -l next_fingerprint (watch_fingerprint)
    if test "$next_fingerprint" = "$last_fingerprint"
        continue
    end

    printf '\n==> Change detected\n'
    sleep 0.2
    generate_project; or continue
    if build_app
        restart_app; or continue
        set last_fingerprint (watch_fingerprint)
    end
end
