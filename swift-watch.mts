#!/usr/bin/env bun

import { $ } from 'bun'
import { statSync } from 'node:fs'
import { join, resolve } from 'node:path'

const BUILD_SCRIPT = join(import.meta.dir, 'swift-build.mts')
const BUILD_DIR_NAME = 'build'
const BUILD_OUT_DIR_NAME = 'out'
const BUILD_META_FILE_NAME = 'meta.json'
const APP_LOG_FILE_NAME = 'app.log'
const WATCH_INTERVAL_MS = 1000

const ROOT_DIR = process.env.ROOT_DIR?.trim() || process.cwd()

function errln(...args: unknown[]) {
  console.error(...args)
}

function isAppBundle(path: string) {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

function resolveConfiguration(value: string) {
  const v = value.toLowerCase()
  if (v === 'debug') return 'Debug'
  if (v === 'release') return 'Release'
  errln(`不支持的模式: ${value}`)
  printHelp()
  process.exit(1)
}

function printHelp() {
  console.log(`用法: bun swift-watch.mts [debug|release] [选项]

配置:
  debug                     Debug 构建（默认）
  release                   Release 构建

选项:
  -c, --configuration, --config <模式>  构建配置：debug 或 release
  --project <路径>                      project.yml 路径
  --scheme <名称>                       Xcode scheme
  --target <名称>                       application target
  -h, --help                            显示帮助`)
}

function parseArgs(argv: string[]) {
  let configuration = 'Debug'
  let projectSpecArg = ''
  let schemeArg = ''
  let targetArg = ''

  let i = 0
  while (i < argv.length) {
    const arg = argv[i]
    const lower = arg.toLowerCase()
    if (arg === '--help' || arg === '-h') {
      printHelp()
      process.exit(0)
    }
    if (arg === '--configuration' || arg === '--config' || arg === '-c') {
      if (i + 1 >= argv.length) {
        errln(`缺少参数值: ${arg}`)
        printHelp()
        process.exit(1)
      }
      configuration = resolveConfiguration(argv[++i])
      i += 1
      continue
    }
    if (lower === 'debug' || lower === 'release') {
      configuration = resolveConfiguration(arg)
      i += 1
      continue
    }
    switch (arg) {
      case '--project':
        if (i + 1 >= argv.length) {
          errln('缺少参数值: --project')
          process.exit(1)
        }
        projectSpecArg = argv[++i]
        break
      case '--scheme':
        if (i + 1 >= argv.length) {
          errln('缺少参数值: --scheme')
          process.exit(1)
        }
        schemeArg = argv[++i]
        break
      case '--target':
        if (i + 1 >= argv.length) {
          errln('缺少参数值: --target')
          process.exit(1)
        }
        targetArg = argv[++i]
        break
      default:
        if (!projectSpecArg) projectSpecArg = arg
        else {
          errln(`未知参数: ${arg}`)
          printHelp()
          process.exit(1)
        }
    }
    i += 1
  }
  return { configuration, projectSpecArg, schemeArg, targetArg }
}

function buildArgs(parsed: ReturnType<typeof parseArgs>) {
  const args = ['--configuration', parsed.configuration === 'Release' ? 'release' : 'debug']
  if (parsed.projectSpecArg) {
    args.push('--project', parsed.projectSpecArg.startsWith('/') ? parsed.projectSpecArg : join(ROOT_DIR, parsed.projectSpecArg))
  }
  if (parsed.schemeArg) args.push('--scheme', parsed.schemeArg)
  if (parsed.targetArg) args.push('--target', parsed.targetArg)
  args.push('--no-open')
  return args
}

async function listWatchFiles() {
  const git = Bun.spawn(['git', '-C', ROOT_DIR, 'rev-parse', '--show-toplevel'], { stdout: 'ignore', stderr: 'ignore' })
  await git.exited
  if (git.exitCode === 0) {
    const proc = Bun.spawn(['git', '-C', ROOT_DIR, 'ls-files', '-co', '--exclude-standard', '--deduplicate'], {
      stdout: 'pipe',
      stderr: 'ignore',
    })
    const text = await new Response(proc.stdout).text()
    await proc.exited
    return text.split('\n').filter(Boolean)
  }

  const glob = new Bun.Glob('**/*')
  const skip = ['/.git/', '/build/', '/DerivedData/', '/.build/']
  const files: string[] = []
  for await (const rel of glob.scan({ cwd: ROOT_DIR, onlyFiles: true })) {
    const full = join(ROOT_DIR, rel)
    if (skip.some((s) => full.includes(s))) continue
    files.push(rel)
  }
  return files
}

async function watchFingerprint() {
  const lines: string[] = []
  for (const relPath of [...(await listWatchFiles())].sort((a, b) => a.localeCompare(b, 'en'))) {
    const full = join(ROOT_DIR, relPath)
    const f = Bun.file(full)
    if (!(await f.exists())) continue
    lines.push(`${f.lastModified} ${full}`)
  }
  const h = new Bun.CryptoHasher('sha1')
  h.update(lines.join('\n'))
  return h.digest('hex')
}

async function buildOnce(parsed: ReturnType<typeof parseArgs>) {
  const proc = Bun.spawn(['bun', BUILD_SCRIPT, ...buildArgs(parsed)], {
    cwd: ROOT_DIR,
    stdout: 'inherit',
    stderr: 'inherit',
    stdin: 'inherit',
    env: { ...process.env, ROOT_DIR },
  })
  await proc.exited
  return proc.exitCode === 0
}

type BuildMeta = { PRODUCT_PATH: string }

async function loadMeta() {
  const buildMetaPath = join(ROOT_DIR, BUILD_DIR_NAME, BUILD_OUT_DIR_NAME, BUILD_META_FILE_NAME)
  if (!(await Bun.file(buildMetaPath).exists())) {
    errln(`缺少构建元信息: ${buildMetaPath}`)
    process.exit(1)
  }
  return {
    meta: (await Bun.file(buildMetaPath).json()) as BuildMeta,
    appLogPath: join(ROOT_DIR, BUILD_DIR_NAME, BUILD_OUT_DIR_NAME, APP_LOG_FILE_NAME),
  }
}

async function resolveExecutableName(productPath: string) {
  const plist = join(productPath, 'Contents/Info.plist')
  const proc = Bun.spawn(['/usr/libexec/PlistBuddy', '-c', 'Print :CFBundleExecutable', plist], {
    stdout: 'pipe',
    stderr: 'ignore',
  })
  const text = (await new Response(proc.stdout).text()).trim()
  await proc.exited
  return proc.exitCode === 0 ? text : ''
}

async function restartApp(productPath: string, appLogPath: string) {
  if (!isAppBundle(productPath)) {
    errln(`缺少构建产物: ${productPath}`)
    process.exit(1)
  }
  const executableName = await resolveExecutableName(productPath)
  if (executableName) {
    await $`pkill -x ${executableName}`.quiet().nothrow()
    await Bun.sleep(200)
  }
  const child = Bun.spawn(['open', '-n', productPath], { detached: true, stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' })
  child.unref()
  console.log(`已启动: ${productPath}`)
  console.log(`App 日志: ${appLogPath}`)
}

if (!(await Bun.file(BUILD_SCRIPT).exists())) {
  errln(`缺少构建脚本: ${BUILD_SCRIPT}`)
  process.exit(1)
}

const parsed = parseArgs(process.argv.slice(2))

if (!(await buildOnce(parsed))) process.exit(1)
let { meta, appLogPath } = await loadMeta()
await restartApp(meta.PRODUCT_PATH, appLogPath)

let lastFingerprint = await watchFingerprint()
console.log(`监听目录: ${ROOT_DIR}`)

while (true) {
  await Bun.sleep(WATCH_INTERVAL_MS)
  const nextFingerprint = await watchFingerprint()
  if (nextFingerprint === lastFingerprint) continue

  console.log('\n==> 检测到变更')
  await Bun.sleep(200)
  if (await buildOnce(parsed)) {
    try {
      ;({ meta, appLogPath } = await loadMeta())
      await restartApp(meta.PRODUCT_PATH, appLogPath)
      lastFingerprint = await watchFingerprint()
    } catch {
      // keep watching
    }
  }
}
