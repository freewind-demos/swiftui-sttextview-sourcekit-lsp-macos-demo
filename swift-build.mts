#!/usr/bin/env bun

import { $ } from 'bun'
import { statSync } from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'

const SCRIPT_NAME = 'swift-build.mts'
const DEVELOPER_DIR = '/Applications/Xcode.app/Contents/Developer'
const XCODEBUILD_BIN = join(DEVELOPER_DIR, 'usr/bin/xcodebuild')
const BUILD_DIR_NAME = 'build'
const BUILD_OUT_DIR_NAME = 'out'
const BUILD_META_FILE_NAME = 'meta.json'

const ROOT_DIR = process.env.ROOT_DIR?.trim() || process.cwd()

function errln(...args: unknown[]) {
  console.error(...args)
}

// @rule macOS .app 是目录 bundle，用 stat.isDirectory 校验，不用 Bun.file().exists()
function isAppBundle(path: string) {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}

function failProjectSpec(...args: unknown[]) {
  errln(...args)
  errln(`请修正: ${projectSpec || ROOT_DIR}`)
  process.exit(1)
}

function failYamlField(fieldPath: string, message: string) {
  failProjectSpec(`配置错误 ${projectSpec} :: ${fieldPath} -> ${message}`)
}

function requireOnPath(name: string) {
  if (!Bun.which(name)) {
    errln(`缺少命令: ${name}`)
    process.exit(1)
  }
}

function resolveConfiguration(value: string) {
  const v = value.toLowerCase()
  if (v === 'debug' || v === 'd') return 'Debug'
  if (v === 'release' || v === 'r' || v === 'build' || v === 'production' || v === 'prod' || v === 'p') {
    return 'Release'
  }
  errln(`不支持的模式: ${value}`)
  printHelp()
  process.exit(1)
}

function printHelp() {
  console.log(`用法: bun ${SCRIPT_NAME} [debug|release|production] [选项]

配置:
  debug | d                 Debug 构建（默认）
  release | r | build       Release 构建
  production | prod | p     Release 构建（同 release）

选项:
  -c, --configuration, --config <模式>  构建配置（同上）
  --project <路径>                      project.yml 路径
  --scheme <名称>                       Xcode scheme
  --target <名称>                       application target
  --open                                构建后在 Finder 中显示产物（默认）
  --no-open                             构建后不打开 Finder
  -h, --help                            显示帮助

示例:
  bun ${SCRIPT_NAME}
  bun ${SCRIPT_NAME} release --no-open
  bun ${SCRIPT_NAME} --configuration production
  bun ${SCRIPT_NAME} -c debug --scheme freewind_paste`)
}

function parseArgs(argv: string[]) {
  let configuration = 'Debug'
  let projectSpecArg = ''
  let schemeArg = ''
  let targetArg = ''
  let shouldOpen = true

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
    if (['debug', 'd', 'release', 'r', 'build', 'production', 'prod', 'p'].includes(lower)) {
      configuration = resolveConfiguration(arg)
      i += 1
      continue
    }
    if (arg === '--project') {
      if (i + 1 >= argv.length) {
        errln('缺少参数值: --project')
        process.exit(1)
      }
      projectSpecArg = argv[++i]
      i += 1
      continue
    }
    if (arg === '--scheme') {
      if (i + 1 >= argv.length) {
        errln('缺少参数值: --scheme')
        process.exit(1)
      }
      schemeArg = argv[++i]
      i += 1
      continue
    }
    if (arg === '--target') {
      if (i + 1 >= argv.length) {
        errln('缺少参数值: --target')
        process.exit(1)
      }
      targetArg = argv[++i]
      i += 1
      continue
    }
    if (arg === '--no-open') {
      shouldOpen = false
      i += 1
      continue
    }
    if (arg === '--open') {
      shouldOpen = true
      i += 1
      continue
    }
    if (!projectSpecArg) {
      projectSpecArg = arg
      i += 1
      continue
    }
    errln(`未知参数: ${arg}`)
    printHelp()
    process.exit(1)
  }
  return { configuration, projectSpecArg, schemeArg, targetArg, shouldOpen }
}

async function yqText(expr: string, file: string, extraEnv: Record<string, string> = {}) {
  const proc = Bun.spawn(['yq', '-r', expr, file], {
    stdout: 'pipe',
    stderr: 'ignore',
    env: { ...process.env, ...extraEnv },
  })
  const text = (await new Response(proc.stdout).text()).trim()
  await proc.exited
  return proc.exitCode === 0 ? text : ''
}

async function yqList(expr: string, file: string, extraEnv: Record<string, string> = {}) {
  const text = await yqText(expr, file, extraEnv)
  return text ? text.split('\n').map((s) => s.trim()).filter(Boolean) : []
}

function normalizeSpecPath(p: string) {
  return p.startsWith('/') ? p : join(ROOT_DIR, p)
}

async function findProjectSpecs() {
  const glob = new Bun.Glob('**/project.yml')
  const skip = ['/.git/', '/build/', '/DerivedData/', '/.build/']
  const matches: string[] = []
  for await (const path of glob.scan({ cwd: ROOT_DIR, absolute: true, onlyFiles: true })) {
    if (skip.some((s) => path.includes(s))) continue
    matches.push(path)
  }
  return matches
}

const parsed = parseArgs(process.argv.slice(2))
let projectSpec = ''
let projectFile = ''
let projectName = ''
let schemeName = ''
let appTargetName = ''
let productName = ''
const configuration = parsed.configuration
const shouldOpen = parsed.shouldOpen

if (parsed.projectSpecArg) {
  projectSpec = normalizeSpecPath(parsed.projectSpecArg)
  if (!(await Bun.file(projectSpec).exists())) {
    failProjectSpec(`缺少 project.yml: ${projectSpec}。project.yml 是唯一入口，必须包含全部构建信息。`)
  }
} else {
  const matches = await findProjectSpecs()
  if (!matches.length) failProjectSpec(`缺少 project.yml: ${ROOT_DIR}。project.yml 是唯一入口，必须包含全部构建信息。`)
  if (matches.length > 1) {
    errln(`配置错误 ${ROOT_DIR} :: project.yml -> 找到多个文件`)
    for (const m of matches) errln(`  ${m}`)
    errln(`请显式指定: bun ${SCRIPT_NAME} [debug|release|production] --project <project.yml 路径>`)
    process.exit(1)
  }
  projectSpec = matches[0]
}

requireOnPath('yq')
requireOnPath('xcodegen')

projectName = await yqText('.name', projectSpec)
if (!projectName) failYamlField('.name', '缺少')

const schemeNames = await yqList('(.schemes // {}) | keys | .[]', projectSpec)
if (parsed.schemeArg) {
  if (!schemeNames.includes(parsed.schemeArg)) failYamlField('.schemes', `缺少 scheme: ${parsed.schemeArg}`)
  schemeName = parsed.schemeArg
} else if (schemeNames.length === 1) {
  schemeName = schemeNames[0]
} else if (!schemeNames.length) {
  failYamlField('.schemes', '缺少')
} else {
  errln(`配置错误 ${projectSpec} :: .schemes -> 找到多个 scheme`)
  for (const s of schemeNames) errln(`  ${s}`)
  errln(`请显式指定: bun ${SCRIPT_NAME} [debug|release|production] --scheme <scheme 名称>`)
  process.exit(1)
}

const applicationTargetNames = await yqList(
  '.targets // {} | to_entries | map(select((.value.type // "") == "application")) | .[].key',
  projectSpec,
)
if (!applicationTargetNames.length) failYamlField('.targets', '缺少 application target')

if (parsed.targetArg) {
  if (!applicationTargetNames.includes(parsed.targetArg)) failYamlField('.targets', `缺少 application target: ${parsed.targetArg}`)
  appTargetName = parsed.targetArg
} else if (applicationTargetNames.length === 1) {
  appTargetName = applicationTargetNames[0]
} else {
  errln(`配置错误 ${projectSpec} :: .targets -> 找到多个 application target`)
  for (const t of applicationTargetNames) errln(`  ${t}`)
  errln(`请显式指定: bun ${SCRIPT_NAME} [debug|release|production] --target <target 名称>`)
  process.exit(1)
}

const selectedPlatform = await yqText(
  '.targets // {} | to_entries | map(select(.key == strenv(APP_TARGET_NAME))) | .[0].value.platform // ""',
  projectSpec,
  { APP_TARGET_NAME: appTargetName },
)
if (selectedPlatform && selectedPlatform !== 'macOS') {
  failYamlField(`.targets.${appTargetName}.platform`, `必须是 macOS，当前是 ${selectedPlatform}`)
}

const buildTargetNames = await yqList(
  '.schemes // {} | to_entries | map(select(.key == strenv(SCHEME_NAME))) | .[0].value.build.targets // {} | keys | .[]',
  projectSpec,
  { SCHEME_NAME: schemeName },
)
if (buildTargetNames.length > 1) {
  errln(`配置错误 ${projectSpec} :: .schemes.${schemeName}.build.targets -> 必须恰好 1 个 target`)
  for (const t of buildTargetNames) errln(`  ${t}`)
  process.exit(1)
}
if (buildTargetNames.length === 1 && buildTargetNames[0] !== appTargetName) {
  failYamlField(`.schemes.${schemeName}.build.targets`, `必须只包含 ${appTargetName}，当前是 ${buildTargetNames[0]}`)
}

productName = await yqText(
  '.targets // {} | to_entries | map(select(.key == strenv(APP_TARGET_NAME))) | .[0].value.productName // ""',
  projectSpec,
  { APP_TARGET_NAME: appTargetName },
)
if (!productName) failYamlField(`.targets.${appTargetName}.productName`, '缺少')

const outputRoot = join(ROOT_DIR, BUILD_DIR_NAME, BUILD_OUT_DIR_NAME)
const derivedDataDir = join(outputRoot, 'DerivedData')
const productDir = join(outputRoot, configuration)
const productPath = join(productDir, `${productName}.app`)
const buildLogPath = join(outputRoot, `${basename(SCRIPT_NAME, '.mts')}.${configuration.toLowerCase()}.xcodebuild.log`)
const buildMetaPath = join(outputRoot, BUILD_META_FILE_NAME)

await $`rm -rf ${outputRoot}`.quiet()
await $`mkdir -p ${outputRoot} ${derivedDataDir} ${productDir}`.quiet()

const gen = await $`xcodegen generate --spec ${projectSpec}`.nothrow()
if (gen.exitCode !== 0) process.exit(1)

projectFile = join(dirname(projectSpec), `${projectName}.xcodeproj`)
if ((await $`test -d ${projectFile}`.quiet().nothrow()).exitCode !== 0) failProjectSpec(`缺少生成后的工程: ${projectFile}`)

console.log(`\n==> Building ${schemeName} (${configuration})`)
const xb = Bun.spawn(
  [
    XCODEBUILD_BIN,
    '-project',
    projectFile,
    '-scheme',
    schemeName,
    '-configuration',
    configuration,
    '-destination',
    'platform=macOS,arch=x86_64',
    '-derivedDataPath',
    derivedDataDir,
    'ONLY_ACTIVE_ARCH=YES',
    'ARCHS=x86_64',
    `CONFIGURATION_BUILD_DIR=${productDir}`,
    'build',
  ],
  { stdout: 'pipe', stderr: 'pipe', env: { ...process.env, DEVELOPER_DIR } },
)
const [stdout, stderr] = await Promise.all([new Response(xb.stdout).text(), new Response(xb.stderr).text()])
await xb.exited
if (stdout) {
  process.stdout.write(stdout)
  await Bun.write(buildLogPath, stdout)
}
if (stderr) process.stderr.write(stderr)
if (xb.exitCode !== 0) {
  errln('构建失败')
  process.exit(1)
}
if (!isAppBundle(productPath)) failProjectSpec(`缺少构建产物: ${productPath}`)

await Bun.write(
  buildMetaPath,
  `${JSON.stringify(
    {
      ROOT_DIR,
      PROJECT_SPEC: projectSpec,
      PROJECT_FILE: projectFile,
      PROJECT_NAME: projectName,
      SCHEME_NAME: schemeName,
      APP_TARGET_NAME: appTargetName,
      PRODUCT_NAME: productName,
      CONFIGURATION: configuration,
      OUTPUT_ROOT: outputRoot,
      DERIVED_DATA_DIR: derivedDataDir,
      PRODUCT_DIR: productDir,
      PRODUCT_PATH: productPath,
      BUILD_LOG_PATH: buildLogPath,
    },
    null,
    2,
  )}\n`,
)

if (shouldOpen) {
  const linkedPath = join(outputRoot, basename(productPath))
  await $`rm -f ${linkedPath}`.quiet().nothrow()
  await $`ln -sfn ${productPath} ${linkedPath}`.quiet()
  await $`open -R ${linkedPath}`.quiet()
}

console.log(`Project spec: ${projectSpec}`)
console.log(`Project: ${projectFile}`)
console.log(`Scheme: ${schemeName}`)
console.log(`Target: ${appTargetName}`)
console.log(`Configuration: ${configuration}`)
console.log(`Product: ${productPath}`)
console.log(`Build log: ${buildLogPath}`)
console.log(`Build meta: ${buildMetaPath}`)
