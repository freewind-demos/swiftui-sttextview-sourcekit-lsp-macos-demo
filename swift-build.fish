#!/usr/bin/env fish

if test -z "$ROOT_DIR"
    set -gx ROOT_DIR (pwd)
end

set -g SCRIPT_NAME (basename (status filename))
set -g DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
set -g XCODEBUILD_BIN "$DEVELOPER_DIR/usr/bin/xcodebuild"

set -g BUILD_DIR_NAME build
set -g BUILD_OUT_DIR_NAME out
set -g DERIVED_DATA_DIR_NAME DerivedData
set -g BUILD_META_FILE_NAME meta.env

set -g PROJECT_SPEC ""
set -g PROJECT_SPEC_ARG ""
set -g PROJECT_FILE ""
set -g PROJECT_NAME ""
set -g SCHEME_NAME ""
set -g SCHEME_ARG ""
set -g APP_TARGET_NAME ""
set -g TARGET_ARG ""
set -g PRODUCT_NAME ""
set -g CONFIGURATION Debug
set -g SHOULD_OPEN 1

set -g OUTPUT_ROOT ""
set -g DERIVED_DATA_DIR ""
set -g PRODUCT_DIR ""
set -g PRODUCT_PATH ""
set -g BUILD_LOG_PATH ""
set -g BUILD_META_PATH ""

function errln
    printf '%s\n' $argv >&2
end

function fail_project_spec
    set -l hint_path "$PROJECT_SPEC"
    if test -z "$hint_path"
        set hint_path "$ROOT_DIR"
    end
    errln $argv
    errln "请修正: $hint_path"
    return 1
end

function fail_yaml_field
    set -l field_path "$argv[1]"
    set -l message "$argv[2]"
    fail_project_spec "配置错误 $PROJECT_SPEC :: $field_path -> $message"
end

function require_command
    set -l command_name "$argv[1]"
    if not command -sq "$command_name"
        errln "缺少命令: $command_name"
        return 1
    end
end

function resolve_configuration
    switch (string lower -- "$argv[1]")
        case debug d ''
            printf 'Debug\n'
        case release r build
            printf 'Release\n'
        case '*'
            errln "不支持的模式: $argv[1]"
            errln "用法: ./$SCRIPT_NAME [debug|release] [--project 路径] [--scheme 名称] [--target 名称] [--no-open]"
            return 1
    end
end

function parse_args
    set -g CONFIGURATION Debug
    set -g PROJECT_SPEC_ARG ""
    set -g SCHEME_ARG ""
    set -g TARGET_ARG ""
    set -g SHOULD_OPEN 1

    while test (count $argv) -gt 0
        set -l arg_lower (string lower -- "$argv[1]")
        switch "$arg_lower"
            case debug d release r build
                set -g CONFIGURATION (resolve_configuration "$argv[1]"); or return 1
                set argv $argv[2..-1]
            case --project
                if test (count $argv) -lt 2
                    errln "缺少参数值: --project"
                    return 1
                end
                set -g PROJECT_SPEC_ARG "$argv[2]"
                set argv $argv[3..-1]
            case --scheme
                if test (count $argv) -lt 2
                    errln "缺少参数值: --scheme"
                    return 1
                end
                set -g SCHEME_ARG "$argv[2]"
                set argv $argv[3..-1]
            case --target
                if test (count $argv) -lt 2
                    errln "缺少参数值: --target"
                    return 1
                end
                set -g TARGET_ARG "$argv[2]"
                set argv $argv[3..-1]
            case --no-open
                set -g SHOULD_OPEN 0
                set argv $argv[2..-1]
            case --open
                set -g SHOULD_OPEN 1
                set argv $argv[2..-1]
            case '*'
                if test -z "$PROJECT_SPEC_ARG"
                    set -g PROJECT_SPEC_ARG "$argv[1]"
                    set argv $argv[2..-1]
                else
                    errln "用法: ./$SCRIPT_NAME [debug|release] [--project 路径] [--scheme 名称] [--target 名称] [--no-open]"
                    return 1
                end
        end
    end
    return 0
end

function yaml_scalar
    yq -r "$argv[1] // \"\"" "$PROJECT_SPEC" 2>/dev/null
end

function yaml_list
    yq -r "$argv[1]" "$PROJECT_SPEC" 2>/dev/null
end

function normalize_spec_path
    if string match -qr '^/' -- "$argv[1]"
        printf '%s\n' "$argv[1]"
    else
        printf '%s/%s\n' "$ROOT_DIR" "$argv[1]"
    end
end

function resolve_project_spec
    if test -n "$PROJECT_SPEC_ARG"
        set -g PROJECT_SPEC (normalize_spec_path "$PROJECT_SPEC_ARG")
        if not test -f "$PROJECT_SPEC"
            fail_project_spec "缺少 project.yml: $PROJECT_SPEC。project.yml 是唯一入口，必须包含全部构建信息。"
            return 1
        end
        return 0
    end

    set -l matches (fd -HI -a -t f -g 'project.yml' "$ROOT_DIR" --exclude .git --exclude build --exclude DerivedData --exclude .build)
    switch (count $matches)
        case 0
            fail_project_spec "缺少 project.yml: $ROOT_DIR。project.yml 是唯一入口，必须包含全部构建信息。"
            return 1
        case 1
            set -g PROJECT_SPEC "$matches[1]"
            return 0
        case '*'
            errln "配置错误 $ROOT_DIR :: project.yml -> 找到多个文件"
            for match in $matches
                errln "  $match"
            end
            errln "请显式指定: ./$SCRIPT_NAME [debug|release] --project <project.yml 路径>"
            return 1
    end
end

function list_scheme_names
    yaml_list '(.schemes // {}) | keys | .[]'
end

function list_application_target_names
    yaml_list '.targets // {} | to_entries | map(select((.value.type // "") == "application")) | .[].key'
end

function choose_scheme_name
    set -l scheme_names $argv
    if test -n "$SCHEME_ARG"
        if contains -- "$SCHEME_ARG" $scheme_names
            set -g SCHEME_NAME "$SCHEME_ARG"
            return 0
        end
        fail_yaml_field '.schemes' "缺少 scheme: $SCHEME_ARG"
        return 1
    end

    switch (count $scheme_names)
        case 0
            fail_yaml_field '.schemes' '缺少'
            return 1
        case 1
            set -g SCHEME_NAME "$scheme_names[1]"
            return 0
        case '*'
            errln "配置错误 $PROJECT_SPEC :: .schemes -> 找到多个 scheme"
            for scheme_name in $scheme_names
                errln "  $scheme_name"
            end
            errln "请显式指定: ./$SCRIPT_NAME [debug|release] --scheme <scheme 名称>"
            return 1
    end
end

function choose_app_target_name
    set -l target_names $argv
    if test -n "$TARGET_ARG"
        if contains -- "$TARGET_ARG" $target_names
            set -g APP_TARGET_NAME "$TARGET_ARG"
            return 0
        end
        fail_yaml_field '.targets' "缺少 application target: $TARGET_ARG"
        return 1
    end

    switch (count $target_names)
        case 0
            fail_yaml_field '.targets' '缺少 application target'
            return 1
        case 1
            set -g APP_TARGET_NAME "$target_names[1]"
            return 0
        case '*'
            errln "配置错误 $PROJECT_SPEC :: .targets -> 找到多个 application target"
            for target_name in $target_names
                errln "  $target_name"
            end
            errln "请显式指定: ./$SCRIPT_NAME [debug|release] --target <target 名称>"
            return 1
    end
end

function validate_selected_target_platform
    set -l selected_platform (env APP_TARGET_NAME="$APP_TARGET_NAME" yq -r '.targets // {} | to_entries | map(select(.key == strenv(APP_TARGET_NAME))) | .[0].value.platform // ""' "$PROJECT_SPEC" 2>/dev/null)
    if test "$selected_platform" != "" -a "$selected_platform" != "macOS"
        fail_yaml_field ".targets.$APP_TARGET_NAME.platform" "必须是 macOS，当前是 $selected_platform"
        return 1
    end
end

function read_selected_scheme_build_target_names
    env SCHEME_NAME="$SCHEME_NAME" yq -r '.schemes // {} | to_entries | map(select(.key == strenv(SCHEME_NAME))) | .[0].value.build.targets // {} | keys | .[]' "$PROJECT_SPEC" 2>/dev/null
end

function validate_scheme_target_match
    set -l build_target_names (read_selected_scheme_build_target_names)
    switch (count $build_target_names)
        case 0
            return 0
        case 1
        case '*'
            errln "配置错误 $PROJECT_SPEC :: .schemes.$SCHEME_NAME.build.targets -> 必须恰好 1 个 target"
            for target_name in $build_target_names
                errln "  $target_name"
            end
            errln "请修正，或显式指定别的 scheme/target"
            return 1
    end

    if test "$build_target_names[1]" = "$APP_TARGET_NAME"
        return 0
    end
    fail_yaml_field ".schemes.$SCHEME_NAME.build.targets" "必须只包含 $APP_TARGET_NAME，当前是 $build_target_names[1]"
    return 1
end

function validate_project_spec
    set -g PROJECT_NAME (yaml_scalar '.name')
    if test -z "$PROJECT_NAME"
        fail_yaml_field '.name' '缺少'
        return 1
    end

    choose_scheme_name (list_scheme_names); or return 1

    set -l application_target_names (list_application_target_names)
    if test (count $application_target_names) -eq 0
        fail_yaml_field '.targets' '缺少 application target'
        return 1
    end
    choose_app_target_name $application_target_names; or return 1
    validate_selected_target_platform; or return 1
    validate_scheme_target_match; or return 1

    set -g PRODUCT_NAME (env APP_TARGET_NAME="$APP_TARGET_NAME" yq -r '.targets // {} | to_entries | map(select(.key == strenv(APP_TARGET_NAME))) | .[0].value.productName // ""' "$PROJECT_SPEC" 2>/dev/null)
    if test -z "$PRODUCT_NAME"
        fail_yaml_field ".targets.$APP_TARGET_NAME.productName" '缺少'
        return 1
    end
end

function prepare_paths
    set -g OUTPUT_ROOT "$ROOT_DIR/$BUILD_DIR_NAME/$BUILD_OUT_DIR_NAME"
    set -g DERIVED_DATA_DIR "$OUTPUT_ROOT/$DERIVED_DATA_DIR_NAME"
    set -g PRODUCT_DIR "$OUTPUT_ROOT/$CONFIGURATION"
    set -g PRODUCT_PATH "$PRODUCT_DIR/$PRODUCT_NAME.app"
    set -g BUILD_LOG_PATH "$OUTPUT_ROOT/"(path change-extension "" "$SCRIPT_NAME")"."(string lower -- "$CONFIGURATION")".xcodebuild.log"
    set -g BUILD_META_PATH "$OUTPUT_ROOT/$BUILD_META_FILE_NAME"
    rm -rf "$OUTPUT_ROOT"
    mkdir -p "$OUTPUT_ROOT" "$DERIVED_DATA_DIR" "$PRODUCT_DIR"
end

function generate_project
    xcodegen generate --spec "$PROJECT_SPEC"; or return 1
    set -l project_dir (dirname "$PROJECT_SPEC")
    set -g PROJECT_FILE "$project_dir/$PROJECT_NAME.xcodeproj"
    if not test -d "$PROJECT_FILE"
        fail_project_spec "缺少生成后的工程: $PROJECT_FILE"
        return 1
    end
end

function xcodebuild_base_args
    printf '%s\n' \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME_NAME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS,arch=x86_64' \
        -derivedDataPath "$DERIVED_DATA_DIR" \
        ONLY_ACTIVE_ARCH=YES \
        ARCHS=x86_64 \
        CONFIGURATION_BUILD_DIR="$PRODUCT_DIR"
end

function build_product
    printf '\n==> Building %s (%s)\n' "$SCHEME_NAME" "$CONFIGURATION"
    "$XCODEBUILD_BIN" (xcodebuild_base_args) build | tee "$BUILD_LOG_PATH"
    set -l cmd_status $pipestatus[1]
    if test $cmd_status -ne 0
        errln '构建失败'
        return 1
    end
    if not test -d "$PRODUCT_PATH"
        fail_project_spec "缺少构建产物: $PRODUCT_PATH"
        return 1
    end
end

function write_meta
    begin
        printf 'set -gx ROOT_DIR %s\n' (string escape -- "$ROOT_DIR")
        printf 'set -gx PROJECT_SPEC %s\n' (string escape -- "$PROJECT_SPEC")
        printf 'set -gx PROJECT_FILE %s\n' (string escape -- "$PROJECT_FILE")
        printf 'set -gx PROJECT_NAME %s\n' (string escape -- "$PROJECT_NAME")
        printf 'set -gx SCHEME_NAME %s\n' (string escape -- "$SCHEME_NAME")
        printf 'set -gx APP_TARGET_NAME %s\n' (string escape -- "$APP_TARGET_NAME")
        printf 'set -gx PRODUCT_NAME %s\n' (string escape -- "$PRODUCT_NAME")
        printf 'set -gx CONFIGURATION %s\n' (string escape -- "$CONFIGURATION")
        printf 'set -gx OUTPUT_ROOT %s\n' (string escape -- "$OUTPUT_ROOT")
        printf 'set -gx DERIVED_DATA_DIR %s\n' (string escape -- "$DERIVED_DATA_DIR")
        printf 'set -gx PRODUCT_DIR %s\n' (string escape -- "$PRODUCT_DIR")
        printf 'set -gx PRODUCT_PATH %s\n' (string escape -- "$PRODUCT_PATH")
        printf 'set -gx BUILD_LOG_PATH %s\n' (string escape -- "$BUILD_LOG_PATH")
    end > "$BUILD_META_PATH"
end

function reveal_product
    set -l linked_path "$OUTPUT_ROOT/"(basename "$PRODUCT_PATH")
    ln -sfn "$PRODUCT_PATH" "$linked_path"
    open -R "$linked_path"
end

function print_summary
    printf 'Project spec: %s\n' "$PROJECT_SPEC"
    printf 'Project: %s\n' "$PROJECT_FILE"
    printf 'Scheme: %s\n' "$SCHEME_NAME"
    printf 'Target: %s\n' "$APP_TARGET_NAME"
    printf 'Configuration: %s\n' "$CONFIGURATION"
    printf 'Product: %s\n' "$PRODUCT_PATH"
    printf 'Build log: %s\n' "$BUILD_LOG_PATH"
    printf 'Build meta: %s\n' "$BUILD_META_PATH"
end

parse_args $argv; or exit 1
require_command fd; or exit 1
require_command yq; or exit 1
require_command xcodegen; or exit 1
resolve_project_spec; or exit 1
validate_project_spec; or exit 1
prepare_paths
generate_project; or exit 1
build_product; or exit 1
write_meta
if test "$SHOULD_OPEN" = 1
    reveal_product; or exit 1
end
print_summary
