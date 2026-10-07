import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import { defineConfig, type PluginOption } from 'vite'
import { visualizer } from 'rollup-plugin-visualizer'
import { viteStaticCopy } from 'vite-plugin-static-copy'

/** Mirror naming helpers from `@mlightcad/cad-simple-viewer` (not shipped there). */
const LIBREDWG_CONVERTER_PACKAGE = '@mlightcad/libredwg-converter'
const LIBREDWG_PARSER_WORKER_FILE = 'libredwg-parser-worker.js'
const LIBREDWG_PARSER_WASM_FILE = 'libredwg-web.wasm'
const MTEXT_RENDERER_WORKER_FILE = 'mtext-renderer-worker.js'

/**
 * Split heavy peer deps into their own chunks so `cad-simple-viewer-*.js` stays
 * smaller and each package can be cached independently.
 *
 * Keep `data-model` with `geometry-engine` / `graphic-interface` / `common`
 * (tight class hierarchy). Keep `mtext-*` / `shx-parser` with `three-renderer`
 * so they are not absorbed into `cad-simple-viewer` and create a circular chunk
 * edge. `three` includes `three/examples/jsm/*`.
 *
 * Keep Vite's `__vitePreload` helper out of the viewer chunk. Otherwise Rollup
 * places it inside `cad-simple-viewer`, and the tiny app entry must statically
 * import that whole chunk (plus three / data-model) just to call dynamic import.
 */
function viewerManualChunk(id: string): string | undefined {
  const path = id.replace(/\\/g, '/')
  if (
    path.includes('vite/preload-helper') ||
    path.includes('vite/modulepreload-polyfill')
  ) {
    return 'vite-preload'
  }
  if (
    path.includes('/node_modules/three/') ||
    path.includes('/node_modules/.pnpm/three@')
  ) {
    return 'three'
  }
  if (
    path.includes('/@mlightcad/three-renderer/') ||
    path.includes('/@mlightcad/mtext-renderer/') ||
    path.includes('/@mlightcad/mtext-parser/') ||
    path.includes('/@mlightcad/shx-parser/')
  ) {
    return 'three-renderer'
  }
  if (
    path.includes('/@mlightcad/data-model/') ||
    path.includes('/@mlightcad/geometry-engine/') ||
    path.includes('/@mlightcad/graphic-interface/') ||
    path.includes('/@mlightcad/common/')
  ) {
    return 'data-model'
  }
  if (path.includes('/@mlightcad/cad-simple-viewer/')) {
    return 'cad-simple-viewer'
  }
}

const viewerRuntimeSrc = resolve(
  __dirname,
  'node_modules/@mlightcad/cad-html-plugin/dist/viewer-runtime.iife.js'
)
const hasViewerRuntime = existsSync(viewerRuntimeSrc)

const libredwgDist = `./node_modules/${LIBREDWG_CONVERTER_PACKAGE}/dist`

/**
 * mlightcad/cad-data 的位置（字体/数据/模板）。
 * build.py 会先克隆它、再把这里指过去；也可用环境变量 CAD_DATA_DIR 覆盖。
 */
const CAD_DATA_DIR = process.env.CAD_DATA_DIR || resolve(__dirname, 'cad-data')
const libredwgWasmSrc = resolve(
  __dirname,
  'node_modules',
  LIBREDWG_CONVERTER_PACKAGE,
  'dist',
  LIBREDWG_PARSER_WASM_FILE
)

if (!hasViewerRuntime) {
  console.warn(
    '[cad-simple-viewer-example] viewer-runtime.iife.js not found — HTML export (chtml) unavailable. ' +
      'Opening DXF/DWG does not require @mlightcad/cad-html-plugin.'
  )
}

export default defineConfig(({ mode }) => ({
  base: './',
  build: {
    modulePreload: false,
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        'no-plugin': resolve(__dirname, 'no-plugin.html')
      },
      output: {
        manualChunks: viewerManualChunk
      }
    }
  },
  plugins: [
    viteStaticCopy({
      targets: [
        {
          src: `./node_modules/@mlightcad/cad-simple-viewer/dist/${MTEXT_RENDERER_WORKER_FILE}`,
          dest: 'assets',
          rename: { stripBase: true }
        },
        {
          src: `${libredwgDist}/${LIBREDWG_PARSER_WORKER_FILE}`,
          dest: 'assets',
          rename: { stripBase: true }
        },
        ...(existsSync(libredwgWasmSrc)
          ? [
              {
                src: `${libredwgDist}/${LIBREDWG_PARSER_WASM_FILE}`,
                dest: 'assets',
                rename: { stripBase: true }
              }
            ]
          : []),
        ...(hasViewerRuntime
          ? [
              {
                src: './node_modules/@mlightcad/cad-html-plugin/dist/viewer-runtime.iife.js',
                dest: 'assets',
                rename: { stripBase: true }
              }
            ]
          : []),
        // ── cad-data：字体 / 数据 / 模板 ────────────────────────────────────
        // ⚠️ 官方示例把 `baseUrl` 指向公网 CDN（cdn.jsdelivr.net/gh/mlightcad/cad-data）。
        //    本应用是**内网 NAS 应用**，绝不能依赖公网（离线就废，还会暴露访问行为），
        //    所以把这份数据一起打进产物、由本地 ./cad-data/ 提供（见 src/app.ts 的 baseUrl）。
        //    其中 fonts/ 里有 86 个 .shx —— **CAD 图纸用的就是 SHX 字体**，
        //    这也是它比 FileView 自带的 cad2x 字体还原好得多的原因。
        //    路径可用 CAD_DATA_DIR 覆盖（build.py 会把它指向克隆下来的 cad-data）。
        {
          src: `${CAD_DATA_DIR}/fonts/*`,
          dest: 'cad-data/fonts',
          rename: { stripBase: true }
        },
        {
          src: `${CAD_DATA_DIR}/data/*`,
          dest: 'cad-data/data',
          rename: { stripBase: true }
        },
        {
          src: `${CAD_DATA_DIR}/templates/*`,
          dest: 'cad-data/templates',
          rename: { stripBase: true }
        }
      ]
    }),
    mode === 'analyze' &&
      visualizer({ filename: 'stats.html', gzipSize: true, brotliSize: true })
  ].filter(Boolean) as PluginOption[]
}))
