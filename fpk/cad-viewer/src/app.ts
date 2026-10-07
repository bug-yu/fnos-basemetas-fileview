import type {
  AcApDocManager,
  AcApOpenDatabaseOptions,
  AcApOpenViewMode,
  AcEdOpenMode
} from '@mlightcad/cad-simple-viewer'
import {
  loadCadSimpleViewer,
  preloadViewerAppModules,
  scheduleViewerPreload
} from './viewerLoader'
import { WEBWORKER_FILE_URLS } from './workerConfig'

/**
 * Toast notification severity used by {@link CadViewerApp.showMessage}.
 */
type MessageType = 'success' | 'error' | 'info'

/**
 * Upload-screen value for initial view when the user leaves the choice on **Auto**.
 */
type OpenViewModeChoice = 'auto' | AcApOpenViewMode

/**
 * Open options collected from the upload screen before a file is loaded.
 */
interface OpenOptions {
  /** Database access mode passed to {@link AcApOpenDatabaseOptions.mode}. */
  mode: AcEdOpenMode
  /** Whether MTEXT is rendered on the main thread (fixed after first {@link CadViewerApp.initialize}). */
  useMainThreadDraw: boolean
  /** Whether non-plottable layers are drawn ({@link AcApOpenDatabaseOptions.drawNoPlotLayers}). */
  drawNoPlotLayers: boolean
  /** Whether geometry is shown incrementally while the file converts. */
  progressiveRendering: boolean
  /** Circle/arc tessellation sides ({@link AcApOpenDatabaseOptions.circleSides}). */
  circleSides: number
  /** Paper-space canvas background RGB (e.g. `0xffffff` white, `0x000000` black). */
  paperSpaceBackground: number
  /**
   * When `true`, hide built-in export commands and skip HTML/SVG plugins
   * (fixed after first {@link CadViewerApp.initialize}).
   */
  disableExport: boolean
  /** How the view is framed after open; omitted when the user selects **Auto**. */
  openViewMode?: AcApOpenViewMode
}

/**
 * Options for {@link CadViewerApp}.
 */
export interface CadViewerAppOptions {
  /**
   * When `true` (default), registers lazy export plugins and the simple UI toolbar.
   * Set to `false` to run a bare `cad-simple-viewer` without any plugins.
   */
  enablePlugins?: boolean
}

/**
 * Application shell that wires the example HTML UI to `AcApDocManager`.
 *
 * Responsibilities:
 * - Keep the homepage free of a static `@mlightcad/cad-simple-viewer` import
 * - Preload viewer JS after first paint, then create the viewer on first file open
 * - Optionally register demo commands, lazy export plugins, and the simple UI plugin
 * - Handle local DXF/DWG file open with configurable open options
 * - Reflect document state in the DOM (upload screen vs viewer)
 *
 * The viewer package and `AcApDocManager.createInstance` are deferred until needed;
 * {@link scheduleViewerPreload} warms the module cache in the background.
 */
export class CadViewerApp {
  /**
   * Host element passed to `AcApDocManager.createInstance` as the WebGL/view canvas parent.
   * Corresponds to `#cad-container` in the page HTML.
   */
  private container: HTMLDivElement

  /**
   * Viewer pane that hosts the CAD canvas and (when enabled) simple UI plugin overlays.
   * Corresponds to `#viewerPane` in the page HTML.
   */
  private viewerPane: HTMLElement

  /**
   * Full-screen upload overlay shown before a drawing is opened.
   * Corresponds to `#uploadScreen` in the page HTML.
   */
  private uploadScreen: HTMLElement

  /**
   * Click/drop target inside the upload panel that triggers the hidden file input.
   * Corresponds to `#uploadDropzone` in the page HTML.
   */
  private uploadDropzone: HTMLElement

  /**
   * Hidden `<input type="file">` used to pick local `.dxf` / `.dwg` files.
   * Corresponds to `#fileInputElement`.
   */
  private fileInput: HTMLInputElement

  /**
   * Compact **Open** control shown in the viewer corner after a file loads successfully.
   * Corresponds to `#reopenButton` in the page HTML.
   */
  private reopenButton: HTMLButtonElement

  /**
   * **New Drawing** button on the upload screen.
   * Corresponds to `#newDrawingButton` in the page HTML.
   */
  private newDrawingButton: HTMLButtonElement

  /**
   * Whether {@link AcApDocManager.createInstance} has completed for this page session.
   * Stays false until the user opens a file for the first time.
   */
  private isInitialized: boolean = false

  /**
   * `useMainThreadDraw` value passed to the first {@link CadViewerApp.initialize} call.
   * Used to warn when the user changes text rendering after the viewer is already running.
   */
  private initUseMainThreadDraw: boolean = false

  /**
   * `disableExport` value passed to the first {@link CadViewerApp.initialize} call.
   * Used to warn when the user changes export availability after the viewer is already running.
   */
  private initDisableExport: boolean = false

  /**
   * Whether the user has opened at least one drawing in this session.
   * Used to keep the corner **Open** button visible after subsequent opens.
   */
  private hasOpenedFile: boolean = false

  /**
   * Whether to register export + simple UI plugins after `createInstance`.
   */
  private readonly enablePlugins: boolean

  /**
   * Cached `AcApDocManager` class after the viewer module has been loaded.
   * Set during {@link CadViewerApp.initialize}.
   */
  private DocManager: typeof AcApDocManager | null = null

  /**
   * Binds DOM references from the page HTML and registers UI event listeners.
   *
   * Does not load `@mlightcad/cad-simple-viewer` or create the CAD viewer;
   * schedules a background preload and initializes on first file open /
   * new drawing.
   *
   * @param options - App options; set `enablePlugins: false` for a bare viewer
   */
  constructor(options: CadViewerAppOptions = {}) {
    this.enablePlugins = options.enablePlugins !== false

    this.container = document.getElementById('cad-container') as HTMLDivElement
    this.viewerPane = document.getElementById('viewerPane') as HTMLElement
    this.uploadScreen = document.getElementById('uploadScreen') as HTMLElement
    this.uploadDropzone = document.getElementById('uploadDropzone') as HTMLElement
    this.fileInput = document.getElementById('fileInputElement') as HTMLInputElement
    this.reopenButton = document.getElementById('reopenButton') as HTMLButtonElement
    this.newDrawingButton = document.getElementById(
      'newDrawingButton'
    ) as HTMLButtonElement

    this.setupOptionGroups()
    this.setupFileHandling()
    this.setupNewDrawingHandling()
    this.setupReopenHandling()
    scheduleViewerPreload(this.enablePlugins)
  }

  /**
   * Wires click handlers on every `[data-option-group]` segment on the upload screen.
   *
   * Toggles the `is-active` class and `aria-checked` on the clicked option.
   */
  private setupOptionGroups(): void {
    document.querySelectorAll('[data-option-group]').forEach(group => {
      group.addEventListener('click', event => {
        const target = (event.target as HTMLElement).closest<HTMLButtonElement>(
          'button[data-value]'
        )
        if (!target || !group.contains(target)) {
          return
        }

        group.querySelectorAll('button[data-value]').forEach(button => {
          const isActive = button === target
          button.classList.toggle('is-active', isActive)
          button.setAttribute('aria-checked', String(isActive))
        })
      })
    })
  }

  /**
   * Returns the `data-value` of the active button inside an open-option group.
   *
   * @param groupName - Value of `data-option-group` on the segment container
   * @returns Selected option value, or an empty string when nothing is active
   */
  private getSelectedValue(groupName: string): string {
    const active = document.querySelector(
      `[data-option-group="${groupName}"] button.is-active`
    ) as HTMLButtonElement | null
    return active?.dataset.value ?? ''
  }

  /**
   * Reads the current upload-screen choices into an {@link OpenOptions} object.
   *
   * @returns Options applied on the next {@link CadViewerApp.loadFile} call
   */
  private readOpenOptions(): OpenOptions {
    const openViewChoice = this.getSelectedValue('openViewMode') as OpenViewModeChoice
    const openViewMode =
      openViewChoice === 'auto' ? undefined : (openViewChoice as AcApOpenViewMode)
    const circleSidesRaw = Number(this.getSelectedValue('circleSides'))
    const paperBgRaw = Number.parseInt(
      this.getSelectedValue('paperSpaceBackground') || 'ffffff',
      16
    )

    return {
      mode: Number(this.getSelectedValue('accessMode')) as AcEdOpenMode,
      useMainThreadDraw: this.getSelectedValue('textRendering') === 'main',
      drawNoPlotLayers: this.getSelectedValue('noPlotLayers') === 'true',
      progressiveRendering: this.getSelectedValue('progressiveRendering') === 'true',
      circleSides: Number.isFinite(circleSidesRaw) ? circleSidesRaw : 50,
      paperSpaceBackground: Number.isFinite(paperBgRaw) ? paperBgRaw : 0xffffff,
      disableExport: this.getSelectedValue('disableExport') === 'true',
      openViewMode
    }
  }

  /**
   * Builds {@link AcApOpenDatabaseOptions} from upload-screen choices, including
   * paper-space background via `paperbkcolor`.
   */
  private buildDatabaseOpenOptions(
    openOptions: OpenOptions,
    layoutBackgroundColorFromRgb: (typeof import('@mlightcad/cad-simple-viewer'))['layoutBackgroundColorFromRgb'],
    extras: Partial<AcApOpenDatabaseOptions> = {}
  ): AcApOpenDatabaseOptions {
    return {
      mode: openOptions.mode,
      drawNoPlotLayers: openOptions.drawNoPlotLayers,
      progressiveRendering: openOptions.progressiveRendering,
      circleSides: openOptions.circleSides,
      sysVars: {
        paperbkcolor: layoutBackgroundColorFromRgb(openOptions.paperSpaceBackground)
      },
      ...(openOptions.openViewMode != null
        ? { openViewMode: openOptions.openViewMode }
        : {}),
      ...extras
    }
  }

  /**
   * Collects warnings when session-fixed options (text rendering / export) differ
   * from the values used on first {@link CadViewerApp.initialize}.
   *
   * Callers should surface these after {@link CadViewerApp.clearMessages} so the
   * toasts are not immediately removed.
   */
  private getSessionOptionWarnings(openOptions: OpenOptions): string[] {
    if (!this.isInitialized) {
      return []
    }
    const warnings: string[] = []
    if (openOptions.useMainThreadDraw !== this.initUseMainThreadDraw) {
      warnings.push(
        'Text rendering mode applies on first load. Reload the page to change it.'
      )
    }
    if (openOptions.disableExport !== this.initDisableExport) {
      warnings.push(
        'Export availability applies on first load. Reload the page to change it.'
      )
    }
    return warnings
  }

  /**
   * Creates the singleton `AcApDocManager` and registers commands, plugins, and listeners.
   *
   * Dynamically imports `@mlightcad/cad-simple-viewer` (reusing any background preload)
   * before calling `createInstance`.
   *
   * Configuration highlights:
   * - LibreDWG DWG converter — host-registered via {@link registerLibreDwgConverter} (GPL opt-in)
   * - `webworkerFileUrls` — MTEXT + LibreDWG worker (+ wasm) copied to `dist/assets/`
   * - `checkWorkersOnInit` — probe worker URLs after registration (see {@link WEBWORKER_FILE_URLS})
   * - `baseUrl` — optional CDN root for built-in resources (demo override)
   * - `useMainThreadDraw` — MTEXT render mode; fixed for the lifetime of the page session
   * - `disableExport` — hides built-in export commands; fixed for the page session
   *
   * HTML export runtime (`viewer-runtime.iife.js`) is configured on the HTML plugin via
   * {@link registerPlugins} / `registerLazyHtmlPlugin({ viewerRuntimeUrl })` — not here.
   *
   * Before `createInstance`, {@link AcApDocManager.checkWebworkerReadiness} verifies
   * that worker scripts respond without downloading large bundles (HEAD + ranged GET fallback).
   * DXF parsing uses the built-in converter in `@mlightcad/data-model` and needs no worker file.
   *
   * Idempotent: subsequent calls are no-ops once {@link CadViewerApp.isInitialized} is true.
   *
   * @param useMainThreadDraw - When `true`, MTEXT is rendered on the main thread instead of a worker
   * @param disableExport - When `true`, hide export commands and skip HTML/SVG plugins
   * @returns `true` when the viewer is ready; `false` when worker checks or init failed
   * @remarks On failure, logs to the console and shows an error toast via {@link CadViewerApp.showMessage}.
   */
  private async initialize(
    useMainThreadDraw: boolean,
    disableExport: boolean
  ): Promise<boolean> {
    if (this.isInitialized) {
      return true
    }

    try {
      // Prefer the shared preload promise so first open awaits in-flight work
      await preloadViewerAppModules(this.enablePlugins)
      const { AcApDocManager, AcEdCommandStack, acedApplyUiTheme } =
        await loadCadSimpleViewer()
      this.DocManager = AcApDocManager

      acedApplyUiTheme('dark', this.viewerPane)

      // Dynamic import keeps LibreDWG / data-model out of the app entry until first open.
      const { registerLibreDwgConverter } = await import('./registerLibreDwg')
      registerLibreDwgConverter(String(WEBWORKER_FILE_URLS.dwgParser))

      const workersReachable = await AcApDocManager.checkWebworkerReadiness(
        WEBWORKER_FILE_URLS
      )
      if (!workersReachable) {
        console.error(
          'CAD worker scripts are missing or blocked:',
          WEBWORKER_FILE_URLS
        )
        this.showMessage(
          'CAD worker scripts are missing. Ensure DWG/MTEXT workers are deployed to assets/.',
          'error'
        )
        return false
      }

      AcApDocManager.createInstance({
        container: this.container,
        busyIndicatorHost: this.viewerPane,
        autoResize: true,
        // ⚠️ 官方示例指向公网 CDN（字体/模板数据）—— 本应用是**内网 NAS 应用**，
        //    绝不能依赖公网：离线就废，还会把访问行为暴露出去。
        //    改成同目录下的本地副本（构建时把 mlightcad/cad-data 的 fonts/data/templates 放进来）。
        baseUrl: './cad-data/',
        webworkerFileUrls: WEBWORKER_FILE_URLS,
        checkWorkersOnInit: true,
        useMainThreadDraw,
        disableExport
      })

      const docManager = AcApDocManager.instance

      docManager.events.workersReady.addEventListener(({ ready }) => {
        if (!ready) {
          console.error('CAD worker scripts are not reachable')
          this.showMessage('CAD worker scripts are not reachable', 'error')
        }
      })

      docManager.events.documentToBeOpened.addEventListener(() => {
        this.setUploadLoading(true)
      })

      const { initializeLocale } = await import('./i8n')
      initializeLocale()
      await this.registerCommands(AcEdCommandStack)

      if (this.enablePlugins) {
        // Dynamic import keeps plugin `/register` stubs out of the bare-viewer entry
        const { registerPlugins } = await import('./register')
        await registerPlugins(this.viewerPane)
      }

      docManager.events.documentActivated.addEventListener(args => {
        document.title = args.doc.docTitle
        if (this.hasOpenedFile) {
          this.showReopenButton()
        }
      })

      this.isInitialized = true
      this.initUseMainThreadDraw = useMainThreadDraw
      this.initDisableExport = disableExport

      // ⚠️ 自动加载**不在这里** —— 本函数是懒调用的（只在选完文件后才跑）。
      //    见 bootCadViewerApp() 里的 app.autoLoadFromQuery()。

      return true
    } catch (error) {
      console.error('Failed to initialize CAD viewer:', error)
      this.showMessage('Failed to initialize CAD viewer', 'error')
      return false
    }
  }

  /**
   * Registers example custom commands on the system command group.
   *
   * Currently adds `ellipsedemo` ({@link AcApEllipseCmd}) for interactive ellipse creation.
   *
   * @param AcEdCommandStack - Command stack class from the loaded viewer module
   * @remarks Must run after {@link CadViewerApp.initialize} so `commandManager` exists.
   */
  private async registerCommands(
    AcEdCommandStack: (typeof import('@mlightcad/cad-simple-viewer'))['AcEdCommandStack']
  ): Promise<void> {
    const { AcApEllipseCmd } = await import('./ellipseCmd')
    const register = this.requireDocManager().instance.commandManager
    register.addCommand(
      AcEdCommandStack.SYSTEMT_COMMAND_GROUP_NAME,
      'ellipsedemo',
      'ellipsedemo',
      new AcApEllipseCmd()
    )
  }

  /**
   * Returns the cached `AcApDocManager` class after successful initialization.
   */
  private requireDocManager(): typeof AcApDocManager {
    if (!this.DocManager) {
      throw new Error('CAD viewer is not initialized')
    }
    return this.DocManager
  }

  /**
   * Attaches drag-and-drop, keyboard, and `change` listeners for local file open.
   *
   * Clears the hidden file input value after each selection so the same file can be chosen again.
   */
  private setupFileHandling(): void {
    this.uploadDropzone.addEventListener('click', () => {
      this.fileInput.click()
    })

    this.uploadDropzone.addEventListener('keydown', event => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault()
        this.fileInput.click()
      }
    })

    this.uploadDropzone.addEventListener('dragover', event => {
      event.preventDefault()
      this.uploadDropzone.classList.add('is-dragover')
    })

    this.uploadDropzone.addEventListener('dragleave', () => {
      this.uploadDropzone.classList.remove('is-dragover')
    })

    this.uploadDropzone.addEventListener('drop', event => {
      event.preventDefault()
      this.uploadDropzone.classList.remove('is-dragover')
      const file = event.dataTransfer?.files?.[0]
      if (file) {
        void this.loadFile(file)
      }
    })

    this.fileInput.addEventListener('change', event => {
      const file = (event.target as HTMLInputElement).files?.[0]
      if (file) {
        void this.loadFile(file)
      }
      this.fileInput.value = ''
    })
  }

  /**
   * Creates a blank drawing when the upload-screen **New Drawing** button is clicked.
   */
  private setupNewDrawingHandling(): void {
    this.newDrawingButton.addEventListener('click', () => {
      void this.createNewDrawing()
    })
  }

  /**
   * Runs the built-in **OPEN** command when the corner **Open** button is clicked.
   */
  private setupReopenHandling(): void {
    this.reopenButton.addEventListener('click', () => {
      if (!this.isInitialized) {
        return
      }
      this.requireDocManager().instance.sendStringToExecute('open')
    })
  }

  /**
   * Initializes the viewer (if needed) and creates a blank document with the
   * current upload-screen open options.
   */
  private async createNewDrawing(): Promise<void> {
    const openOptions = this.readOpenOptions()
    const sessionWarnings = this.getSessionOptionWarnings(openOptions)

    if (
      !(await this.initialize(
        openOptions.useMainThreadDraw,
        openOptions.disableExport
      ))
    ) {
      return
    }

    this.clearMessages()

    try {
      const { layoutBackgroundColorFromRgb } = await loadCadSimpleViewer()
      const options = this.buildDatabaseOpenOptions(
        openOptions,
        layoutBackgroundColorFromRgb
      )

      const success = await this.requireDocManager().instance.newDocument(options)

      if (success) {
        this.hideUploadScreen()
        const base = 'New drawing created'
        this.showMessage(
          sessionWarnings.length > 0
            ? `${base}. ${sessionWarnings.join(' ')}`
            : base,
          sessionWarnings.length > 0 ? 'info' : 'success'
        )
      } else {
        this.showUploadScreen()
        this.showMessage('Failed to create new drawing', 'error')
      }
    } catch (error) {
      console.error('Error creating new drawing:', error)
      this.showUploadScreen()
      this.showMessage(`Error creating new drawing: ${error}`, 'error')
    }
  }

  /**
   * Hides the upload overlay while a document is opening so the viewer loading indicator is visible.
   *
   * Triggered from the `documentToBeOpened` event and when {@link CadViewerApp.loadFile}
   * begins opening a file.
   *
   * @param loading - When `true`, hides the upload screen
   */
  private setUploadLoading(loading: boolean): void {
    if (loading) {
      this.uploadScreen.classList.add('is-hidden')
    }
  }

  /**
   * Restores the full upload screen (home page) after a failed open from the upload flow.
   */
  private showUploadScreen(): void {
    this.uploadScreen.classList.remove('is-hidden')
    this.reopenButton.classList.remove('is-visible')
  }

  /**
   * Shows the compact corner **Open** button while keeping the upload screen hidden.
   */
  private showReopenButton(): void {
    this.uploadScreen.classList.add('is-hidden')
    this.reopenButton.classList.add('is-visible')
  }

  /**
   * Hides the upload screen and shows the compact corner **Open** button after a successful load.
   */
  private hideUploadScreen(): void {
    this.hasOpenedFile = true
    this.showReopenButton()
  }

  /**
   * Reads a local file, validates extension, and opens it in the viewer.
   *
   * Flow:
   * 1. {@link CadViewerApp.readOpenOptions} → {@link CadViewerApp.initialize}
   * 2. Reject non-`.dxf` / non-`.dwg` names with an error toast
   * 3. Hide the upload screen via `documentToBeOpened` while the viewer shows its loading indicator
   * 4. {@link CadViewerApp.readFile} → `openDocument` with upload-screen options
   * 5. On success, {@link CadViewerApp.hideUploadScreen} and a success toast; on failure, {@link CadViewerApp.showUploadScreen}
   *
   * @param file - User-selected file from the file input or drop zone
   */
  private async loadFile(file: File): Promise<void> {
    const openOptions = this.readOpenOptions()
    const sessionWarnings = this.getSessionOptionWarnings(openOptions)

    if (
      !(await this.initialize(
        openOptions.useMainThreadDraw,
        openOptions.disableExport
      ))
    ) {
      return
    }

    const fileName = file.name.toLowerCase()
    if (!fileName.endsWith('.dxf') && !fileName.endsWith('.dwg')) {
      this.showMessage('Please select a DXF or DWG file', 'error')
      return
    }

    this.clearMessages()

    try {
      const docManager = this.requireDocManager().instance
      if (!(await docManager.areWorkersReady())) {
        this.showMessage(
          'CAD worker scripts are not reachable. Check deployment of assets/*-worker.js.',
          'error'
        )
        return
      }

      const fileContent = await this.readFile(file)
      const { layoutBackgroundColorFromRgb } = await loadCadSimpleViewer()
      const options = this.buildDatabaseOpenOptions(
        openOptions,
        layoutBackgroundColorFromRgb,
        { minimumChunkSize: 1000 }
      )

      const success = await docManager.openDocument(
        file.name,
        fileContent,
        options
      )

      if (success) {
        this.hideUploadScreen()
        const base = `Successfully loaded: ${file.name}`
        this.showMessage(
          sessionWarnings.length > 0
            ? `${base}. ${sessionWarnings.join(' ')}`
            : base,
          sessionWarnings.length > 0 ? 'info' : 'success'
        )
      } else {
        this.showUploadScreen()
        this.showMessage(`Failed to load: ${file.name}`, 'error')
      }
    } catch (error) {
      console.error('Error loading file:', error)
      this.showUploadScreen()
      this.showMessage(`Error loading file: ${error}`, 'error')
    }
  }

  /**
   * 本应用专用：从 URL 的 `?path=` 自动加载图纸。
   *
   * 飞牛在「用 FileView 打开」时会把文件**绝对路径**追加为 `path` 查询参数。
   * ⚠️ 文件**不走静态路径**：走同源的 `./api/raw` —— 那个接口挂在网关后面，
   * 由闸门按**逐用户 ACL** 判定，读不到就 403，与 FileView 本身的权限口径一致。
   * 也就是说：这里**不能**绕开权限，否则等于给整个应用开了后门。
   */
  async autoLoadFromQuery(): Promise<void> {
    const q = new URLSearchParams(location.search)
    // 飞牛官方文档说会追加 `path`；这里再兜几个常见写法，免得因为参数名不一致白排查
    let path = q.get('path') || q.get('filePath') || q.get('file') || ''
    if (!path) {
      // 没拿到路径：**把实际收到的参数显示出来** —— 否则只能干瞪眼。
      // （0.5.55 首版就是因为钩子挂错地方、又看不到参数，才白跑一轮 ✗）
      const raw = location.search || '（无查询参数）'
      // eslint-disable-next-line no-console
      console.warn('[fv-cad] 没有收到文件路径，实际查询串：', raw)
      this.showMessage(`没有收到文件路径，URL 参数：${raw}`, 'error')
      return
    }
    if (path.startsWith('file://')) {
      path = decodeURIComponent(path.slice('file://'.length))
    }
    const name = path.split('/').pop() || 'drawing.dwg'
    // ⚠️ 页面刚打开时 CAD worker 可能**还没就绪** —— 直接开有几率报
    //    "CAD worker scripts are not reachable"（示例原本是等用户选文件，天然错开了）。
    //    所以这里退避重试几次；用 this.hasOpenedFile 判断成没成
    //    （它在 documentActivated 事件里置位）。
    for (let attempt = 1; attempt <= 4; attempt++) {
      try {
        this.showMessage(`正在读取 ${name} …`, 'info')
        const res = await fetch(`./api/raw?filePath=${encodeURIComponent(path)}`, {
          credentials: 'same-origin'
        })
        if (!res.ok) {
          // 把服务端返回的原因也带上 —— 否则界面上只有个状态码，没法定位
          // （0.5.56 真机就是只看到「HTTP 400」，还得回来翻代码才知道是路径没解码 ✗）
          let detail = ''
          try {
            detail = (await res.text()).trim().slice(0, 200)
          } catch {
            /* 拿不到就算了 */
          }
          const tail = detail ? `：${detail}` : ''
          this.showMessage(
            res.status === 403
              ? `没有权限读取这个文件${tail}`
              : `读取文件失败（HTTP ${res.status}）${tail}`,
            'error'
          )
          return
        }
        const buf = await res.arrayBuffer()
        await this.loadFile(new File([buf], name))
      } catch (error) {
        this.showMessage(`读取文件出错：${error}`, 'error')
        return
      }
      if (this.hasOpenedFile) return          // 成功
      if (attempt < 4) {
        // eslint-disable-next-line no-console
        console.warn('[fv-cad] 第 %d 次没打开，%dms 后重试', attempt, 400 * attempt)
        await new Promise(r => setTimeout(r, 400 * attempt))
      }
    }
    this.showMessage('加载超时：可直接把图纸拖到下面的框里打开', 'error')
  }

  /**
   * Reads a `File` as raw binary via `FileReader.readAsArrayBuffer`.
   *
   * @param file - Browser `File` object from the file picker or drop zone
   * @returns Promise that resolves to the file contents as `ArrayBuffer`
   * @throws Rejects with the `FileReader` error if reading fails
   */
  private readFile(file: File): Promise<ArrayBuffer> {
    return new Promise((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(reader.result as ArrayBuffer)
      reader.onerror = () => reject(reader.error)
      reader.readAsArrayBuffer(file)
    })
  }

  /**
   * Shows a short-lived centered toast at the top of the viewport.
   *
   * Replaces any existing `.popup-message` elements before creating a new one.
   * Fades out after ~1s and removes the node from the DOM.
   *
   * @param message - Text shown to the user
   * @param type - Controls background and border colors (`success`, `error`, or `info`)
   */
  private showMessage(message: string, type: MessageType = 'info'): void {
    this.clearMessages()

    const popup = document.createElement('div')
    popup.className = `popup-message ${type}`
    popup.textContent = message
    popup.style.position = 'fixed'
    popup.style.top = '2rem'
    popup.style.left = '50%'
    popup.style.transform = 'translateX(-50%)'
    popup.style.zIndex = '1000'
    popup.style.padding = '1rem 2rem'
    popup.style.borderRadius = '8px'
    popup.style.boxShadow = '0 2px 8px rgba(0,0,0,0.15)'
    popup.style.fontSize = '1.1rem'
    popup.style.opacity = '0.98'
    popup.style.transition = 'opacity 0.2s'
    if (type === 'error') {
      popup.style.background = '#ffe6e6'
      popup.style.color = '#dc3545'
      popup.style.border = '1px solid #ffcccc'
    } else if (type === 'success') {
      popup.style.background = '#e6ffe6'
      popup.style.color = '#28a745'
      popup.style.border = '1px solid #ccffcc'
    } else {
      popup.style.background = '#f0f0f0'
      popup.style.color = '#333'
      popup.style.border = '1px solid #ccc'
    }

    document.body.appendChild(popup)

    setTimeout(() => {
      popup.style.opacity = '0'
      setTimeout(() => {
        popup.parentNode?.removeChild(popup)
      }, 200)
    }, 1000)
  }

  /**
   * Removes all in-flight toast elements (class `popup-message`) from `document.body`.
   */
  private clearMessages(): void {
    document.querySelectorAll('.popup-message').forEach(el => el.remove())
  }
}

/**
 * Starts {@link CadViewerApp} once the DOM is ready.
 *
 * @param options - Passed to {@link CadViewerApp}
 */
export function bootCadViewerApp(options: CadViewerAppOptions = {}): void {
  const start = () => {
    const app = new CadViewerApp(options)
    // ★ 本应用专用：**页面一打开**就按 ?path= 自动加载。
    //   ⚠️ 不能挂在 initialize() 里 —— 示例是「懒初始化」，
    //      initialize() 只在用户选完文件后才被调用（loadFile 里），
    //      挂在那边等于永远不触发（0.5.55 首版就是这么错的 ✗）。
    void app.autoLoadFromQuery()
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start)
  } else {
    start()
  }
}
