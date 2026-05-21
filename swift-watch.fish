#!/usr/bin/env fish

if test -z "$ROOT_DIR"
    set -gx ROOT_DIR (pwd)
end

set -g SCRIPT_NAME (basename (status filename))
set -g SCRIPT_DIR (cd (dirname (status filename)); pwd)
set -g BUILD_SCRIPT "$SCRIPT_DIR/swift-build.fish"
set -g BUILD_DIR_NAME build
set -g BUILD_OUT_DIR_NAME out
set -g BUILD_META_FILE_NAME meta.env
set -g APP_LOG_FILE_NAME app.log
set -g WATCH_INTERVAL 1
set -g CONFIGURATION Debug
set -g PROJECT_SPEC_ARG ""
set -g SCHEME_ARG ""
set -g TARGET_ARG ""
set -g BUILD_META_PATH ""
set -g PRODUCT_PATH ""
set -g PRODUCT_NAME ""
set -g APP_LOG_PATH ""

function print_help
    printf '%s\n' \
        "用法: ./$SCRIPT_NAME [debug|release] [--project PATH] [--scheme NAME] [--target NAME] [--help]" \
        "" \
        "作用:" \
        "  监听 Swift 项目变更，重编译并重启 app" \
        "" \
        "参数:" \
        "  debug|d            Debug 构建，默认" \
        "  release|r|build    Release 构建" \
        "  --project PATH     指定 xcodeproj / xcworkspace / 目录" \
        "  --scheme NAME      指定 scheme" \
        "  --target NAME      指定 target" \
        "  --help, -h         输出帮助" \
        "" \
        "默认行为:" \
        "  调用 swift-build.fish --no-open" \
        "  读取 build/out/meta.env" \
        "  检测变更后自动重编译重启"
end

function errln
    printf '%s\n' $argv >&2
end

function resolve_configuration
    switch (string lower -- "$argv[1]")
        case debug d ''
            printf 'Debug\n'
        case release r build
            printf 'Release\n'
        case '*'
            errln "不支持的模式: $argv[1]"
            print_help >&2
            return 1
    end
end

function parse_args
    set -g CONFIGURATION Debug
    set -g PROJECT_SPEC_ARG ""
    set -g SCHEME_ARG ""
    set -g TARGET_ARG ""

    while test (count $argv) -gt 0
        switch "$argv[1]"
            case --help -h
                print_help
                exit 0
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
            case '*'
                if test -z "$PROJECT_SPEC_ARG"
                    set -g PROJECT_SPEC_ARG "$argv[1]"
                    set argv $argv[2..-1]
                else
                    print_help >&2
                    return 1
                end
        end
    end
end

function normalize_project_spec_arg
    if test -z "$PROJECT_SPEC_ARG"
        return 0
    end
    if string match -qr '^/' -- "$PROJECT_SPEC_ARG"
        return 0
    end
    set -g PROJECT_SPEC_ARG "$ROOT_DIR/$PROJECT_SPEC_ARG"
end

function build_args
    printf '%s\n' "$CONFIGURATION"
    if test -n "$PROJECT_SPEC_ARG"
        printf '%s\n' --project
        printf '%s\n' "$PROJECT_SPEC_ARG"
    end
    if test -n "$SCHEME_ARG"
        printf '%s\n' --scheme
        printf '%s\n' "$SCHEME_ARG"
    end
    if test -n "$TARGET_ARG"
        printf '%s\n' --target
        printf '%s\n' "$TARGET_ARG"
    end
    printf '%s\n' --no-open
end

function load_meta
    set -g BUILD_META_PATH "$ROOT_DIR/$BUILD_DIR_NAME/$BUILD_OUT_DIR_NAME/$BUILD_META_FILE_NAME"
    if not test -f "$BUILD_META_PATH"
        errln "缺少构建元信息: $BUILD_META_PATH"
        return 1
    end
    source "$BUILD_META_PATH"
    set -g APP_LOG_PATH "$ROOT_DIR/$BUILD_DIR_NAME/$BUILD_OUT_DIR_NAME/$APP_LOG_FILE_NAME"
end

function resolve_executable_name
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PRODUCT_PATH/Contents/Info.plist" 2>/dev/null
end

function restart_app
    if not test -d "$PRODUCT_PATH"
        errln "缺少构建产物: $PRODUCT_PATH"
        return 1
    end

    set -l executable_name (resolve_executable_name)
    if test -n "$executable_name"
        pkill -x "$executable_name" >/dev/null 2>&1
        sleep 0.2
    end

    nohup open -n "$PRODUCT_PATH" >"$APP_LOG_PATH" 2>&1 </dev/null &
    printf '已启动: %s\n' "$PRODUCT_PATH"
    printf 'App 日志: %s\n' "$APP_LOG_PATH"
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

function build_once
    fish "$BUILD_SCRIPT" (build_args)
end

parse_args $argv; or exit 1
command -sq fd; or begin
    errln '缺少命令: fd'
    exit 1
end
normalize_project_spec_arg

if not test -x "$BUILD_SCRIPT"
    errln "缺少构建脚本: $BUILD_SCRIPT"
    exit 1
end

build_once; or exit 1
load_meta; or exit 1
restart_app; or exit 1

set -l last_fingerprint (watch_fingerprint)
printf '监听目录: %s\n' "$ROOT_DIR"

while true
    sleep "$WATCH_INTERVAL"
    set -l next_fingerprint (watch_fingerprint)
    if test "$next_fingerprint" = "$last_fingerprint"
        continue
    end

    printf '\n==> 检测到变更\n'
    sleep 0.2
    if build_once
        load_meta; or continue
        restart_app; or continue
        set last_fingerprint (watch_fingerprint)
    end
end
