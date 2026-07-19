<script lang="ts">
  import {
    ClipboardPaste,
    Code,
    Columns2,
    Eye,
    EyeOff,
    FilePlus,
    FilePlus2,
    FileText,
    FolderOpen,
    FolderPlus,
    Save,
    ChevronDown,
    ChevronUp,
    Search as SearchIcon,
    X,
  } from "@lucide/svelte";
  import { convertFileSrc, invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import { getCurrentWindow } from "@tauri-apps/api/window";
  import { onMount } from "svelte";
  import { readText } from "@tauri-apps/plugin-clipboard-manager";
  import { open, save } from "@tauri-apps/plugin-dialog";
  import { openUrl } from "@tauri-apps/plugin-opener";

  import { Button } from "$lib/components/ui/button";
  import Editor from "$lib/components/Editor.svelte";
  import Explorer from "$lib/components/Explorer.svelte";
  import FavoritesSidebar from "$lib/components/FavoritesSidebar.svelte";
  import QuickOpen from "$lib/components/QuickOpen.svelte";
  import SearchPanel from "$lib/components/SearchPanel.svelte";
  import TabBar from "$lib/components/TabBar.svelte";
  import {
    MARKDOWN_EXTENSIONS,
    fileName,
    isMarkdownPath,
    remapDocumentSource,
    type DocumentSource,
  } from "$lib/document-state";
  import { removeFavorite, upsertFavorite, type FavoriteEntry } from "$lib/favorites-state";
  import type { FolderEntry } from "$lib/folder-state";
  import {
    isTabDirty,
    moveTab,
    nextActiveTabId,
    tabTitle,
    type Tab,
    type ViewMode,
  } from "$lib/tab-state";

  type OpenedDocument = {
    path: string;
    html: string;
    content: string;
  };

  type StdinDocument = {
    html: string;
    content: string;
  };

  type OpenRequest = {
    path: string | null;
    folderPath: string | null;
    stdinPath: string | null;
    error: string | null;
  };

  let tabs = $state<Tab[]>([]);
  let activeTabId = $state<string | null>(null);
  let activeTab = $derived(tabs.find((tab) => tab.id === activeTabId));

  // The open folder root. Independent of tabs — the explorer stays
  // visible no matter which tabs are open, and opening a document
  // never closes it.
  let folderRoot = $state<string | null>(null);
  let showHiddenFiles = $state(localStorage.getItem("markive-show-hidden-files") === "true");
  $effect(() => {
    localStorage.setItem("markive-show-hidden-files", String(showHiddenFiles));
  });

  // Favorites sidebar visibility is a UI preference, not document or
  // favorites data — it doesn't belong in session.json or
  // favorites.json, so it's stored the same way showHiddenFiles is.
  let favorites = $state<FavoriteEntry[]>([]);
  let favoritesReady = $state(false);
  let failedFavoritePath = $state<string | null>(null);
  let showFavorites = $state(localStorage.getItem("markive-show-favorites") === "true");
  $effect(() => {
    localStorage.setItem("markive-show-favorites", String(showFavorites));
  });

  let quickOpenOpen = $state(false);

  function openQuickOpen() {
    if (folderRoot) quickOpenOpen = true;
  }

  async function openFileFromQuickOpen(path: string) {
    quickOpenOpen = false;
    errorMessage = null;
    try {
      await openPathInTab(path);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  let searchPanelOpen = $state(false);

  function openSearchPanel() {
    if (folderRoot) searchPanelOpen = true;
  }

  async function openSearchMatch(path: string, line: number, matchStart: number, matchEnd: number) {
    searchPanelOpen = false;
    errorMessage = null;
    try {
      await openPathInTab(path);
      // A match only means something in a view that shows source
      // text; Split keeps showing it too, so only Rendered needs to
      // switch.
      if (activeTab?.viewMode === "rendered") {
        await setActiveViewMode("source");
      }
      // The editor's tab swap happens inside its own effect, one tick
      // after activeTabId changes here — the same reason switchToTab
      // defers its scroll restore.
      requestAnimationFrame(() => {
        editorRef?.revealMatch(line, matchStart, matchEnd);
      });
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  // Appearance: an explicit choice, or the macOS appearance (default).
  type ThemePreference = "light" | "dark" | "system";
  const storedTheme = localStorage.getItem("markive-theme");
  let themePreference = $state<ThemePreference>(
    storedTheme === "light" || storedTheme === "dark" ? storedTheme : "system",
  );
  let systemDark = $state(window.matchMedia("(prefers-color-scheme: dark)").matches);
  let isDark = $derived(
    themePreference === "dark" || (themePreference === "system" && systemDark),
  );

  // Reading and editing preferences, persisted app-wide — never beside
  // documents.
  type ProseWidth = "narrow" | "default" | "wide";
  type Preferences = {
    proseWidth: ProseWidth;
    editorFontSize: number;
    lineWrap: boolean;
  };
  const defaultPreferences: Preferences = {
    proseWidth: "default",
    editorFontSize: 14,
    lineWrap: true,
  };
  const PROSE_WIDTHS: Record<ProseWidth, string> = {
    narrow: "40rem",
    default: "46rem",
    wide: "60rem",
  };

  function loadPreferences(): Preferences {
    try {
      const stored: unknown = JSON.parse(localStorage.getItem("markive-preferences") ?? "");
      return { ...defaultPreferences, ...(stored as Partial<Preferences>) };
    } catch {
      return { ...defaultPreferences };
    }
  }

  let preferences = $state<Preferences>(loadPreferences());
  let settingsOpen = $state(false);

  // Moves focus into a dialog when it opens, so keyboard and
  // VoiceOver users land inside it.
  function focusOnMount(node: HTMLElement) {
    node.focus();
  }

  // Command line tool installation, reported inline in Settings.
  let cliStatus = $state<string | null>(null);

  async function installCli() {
    cliStatus = null;
    try {
      await invoke<string>("install_cli");
      cliStatus = "Installed. Open a new terminal window to use `markive`.";
    } catch (error) {
      cliStatus = error instanceof Error ? error.message : String(error);
    }
  }

  // The number input can hold the empty state mid-edit; the editor
  // always gets a usable size.
  let editorFontSize = $derived(
    Math.min(24, Math.max(11, Number(preferences.editorFontSize) || 14)),
  );
  let proseWidth = $derived(PROSE_WIDTHS[preferences.proseWidth] ?? PROSE_WIDTHS.default);

  $effect(() => {
    localStorage.setItem("markive-preferences", JSON.stringify(preferences));
  });
  let errorMessage = $state<string | null>(null);
  let confirmResolve = $state<((choice: "save" | "discard" | "cancel") => void) | null>(null);
  // The tab named in the unsaved-changes dialog while it is open.
  let confirmTabName = $state<string | null>(null);

  // Document-level find, scoped to the active tab.
  let findOpen = $state(false);
  let findQuery = $state("");
  let findIndex = $state(0);
  let sourceFindCount = $state(0);
  let findInput = $state<HTMLInputElement | null>(null);
  let editorRef = $state<{
    setFind: (query: string) => number;
    findNextMatch: () => void;
    findPreviousMatch: () => void;
    getScrollTop: () => number;
    setScrollTop: (top: number) => void;
    undoEdit: () => void;
    redoEdit: () => void;
    forgetTab: (id: string) => void;
    revealMatch: (line: number, matchStart: number, matchEnd: number) => void;
  } | null>(null);

  let isDirty = $derived(activeTab ? isTabDirty(activeTab) : false);
  let isOpening = $state(false);
  let isPasting = $state(false);
  let isDragOver = $state(false);

  function baseDirFor(source: DocumentSource): string | null {
    return source.kind === "file" ? (source.path.slice(0, source.path.lastIndexOf("/")) ?? null) : null;
  }

  let baseDir = $derived(activeTab ? baseDirFor(activeTab.source) : null);

  let documentName = $derived.by(() => {
    if (activeTab) return tabTitle(activeTab);
    return folderRoot ? (folderRoot.split(/[\\/]/).pop() ?? "Markive") : "Markive";
  });
  let sourceLabel = $derived.by(() => {
    if (!activeTab) return folderRoot ?? "No file open";
    return activeTab.source.kind === "file" ? activeTab.source.path : tabTitle(activeTab);
  });

  // Wraps every case-insensitive match in the rendered HTML with a
  // mark element. Operates on the parsed DOM, so text inside tags and
  // attributes is never touched.
  function markMatches(
    html: string,
    query: string,
    activeIndex: number,
  ): { html: string; count: number } {
    if (!query) return { html, count: 0 };

    const parsed = new DOMParser().parseFromString(html, "text/html");
    const walker = parsed.createTreeWalker(parsed.body, NodeFilter.SHOW_TEXT);
    const needle = query.toLowerCase();
    const nodes: Text[] = [];
    while (walker.nextNode()) nodes.push(walker.currentNode as Text);

    let count = 0;
    for (const node of nodes) {
      const text = node.textContent ?? "";
      const lower = text.toLowerCase();
      if (!lower.includes(needle)) continue;

      const fragment = parsed.createDocumentFragment();
      let position = 0;
      let matchAt = lower.indexOf(needle);
      while (matchAt !== -1) {
        fragment.append(parsed.createTextNode(text.slice(position, matchAt)));
        const mark = parsed.createElement("mark");
        mark.id = `find-match-${count}`;
        if (count === activeIndex) mark.setAttribute("data-active", "");
        mark.textContent = text.slice(matchAt, matchAt + query.length);
        fragment.append(mark);
        count += 1;
        position = matchAt + query.length;
        matchAt = lower.indexOf(needle, position);
      }
      fragment.append(parsed.createTextNode(text.slice(position)));
      node.replaceWith(fragment);
    }

    return { html: parsed.body.innerHTML, count };
  }

  // The article shows marked HTML while find is open in a mode with a
  // rendered pane.
  let findResult = $derived.by(() =>
    findOpen && findQuery && activeTab && activeTab.viewMode !== "source"
      ? markMatches(activeTab.renderedHtml, findQuery, findIndex)
      : { html: activeTab?.renderedHtml ?? "", count: 0 },
  );

  let findCount = $derived(
    activeTab?.viewMode === "rendered" ? findResult.count : sourceFindCount,
  );

  // Keep the editor's search query in sync and count its matches.
  $effect(() => {
    if (findOpen && activeTab && activeTab.viewMode !== "rendered") {
      sourceFindCount = editorRef?.setFind(findQuery) ?? 0;
    }
  });

  // Reset the active match when the query changes.
  $effect(() => {
    void findQuery;
    findIndex = 0;
  });

  // Bring the active rendered match into view.
  $effect(() => {
    if (findOpen && activeTab?.viewMode === "rendered" && findResult.count > 0) {
      document.getElementById(`find-match-${findIndex}`)?.scrollIntoView({ block: "center" });
    }
  });

  // Closing find when the active tab changes avoids showing stale
  // match state for the newly focused document.
  $effect(() => {
    void activeTabId;
    closeFind();
  });

  function openFind() {
    if (!activeTab) return;
    findOpen = true;
    queueMicrotask(() => {
      findInput?.focus();
      findInput?.select();
    });
  }

  function closeFind() {
    findOpen = false;
    findQuery = "";
    if (activeTab && activeTab.viewMode !== "rendered") editorRef?.setFind("");
  }

  function findStep(direction: 1 | -1) {
    if (!activeTab) return;

    if (activeTab.viewMode === "rendered") {
      if (findResult.count === 0) return;
      findIndex = (findIndex + direction + findResult.count) % findResult.count;
      return;
    }

    if (direction === 1) editorRef?.findNextMatch();
    else editorRef?.findPreviousMatch();
  }

  function handleFindKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      event.preventDefault();
      closeFind();
    }
    if (event.key === "Enter") {
      event.preventDefault();
      findStep(event.shiftKey ? -1 : 1);
    }
  }

  // The backend resolves local image sources to absolute filesystem
  // paths; the webview can only load them through the asset protocol.
  function convertLocalImageSources(html: string): string {
    const parsed = new DOMParser().parseFromString(html, "text/html");

    for (const image of parsed.querySelectorAll("img")) {
      const src = image.getAttribute("src");
      if (!src?.startsWith("/")) continue;

      try {
        image.setAttribute("src", convertFileSrc(decodeURIComponent(src)));
      } catch {
        // Malformed percent-encoding: leave the source as-is; the
        // image stays a broken reference with its alt text.
      }
    }

    return parsed.body.innerHTML;
  }

  async function renderMarkdown(markdown: string, path: string | null): Promise<string> {
    const html = await invoke<string>("render_source", {
      markdown,
      baseDir: path ? path.slice(0, path.lastIndexOf("/")) : null,
    });
    return convertLocalImageSources(html);
  }

  // Appends a new tab built from the given fields and focuses it.
  function openTab(fields: Omit<Tab, "id">): Tab {
    const tab: Tab = { ...fields, id: crypto.randomUUID() };
    tabs = [...tabs, tab];
    switchToTab(tab.id);
    return tab;
  }

  // Switches the active tab, snapshotting the outgoing tab's scroll
  // position first so it's there to restore if the user comes back.
  function switchToTab(id: string) {
    if (activeTab) {
      activeTab.scroll = {
        rendered: renderedScrollEl?.scrollTop ?? 0,
        source: editorRef?.getScrollTop() ?? 0,
      };
    }

    activeTabId = id;

    requestAnimationFrame(() => {
      const tab = tabs.find((candidate) => candidate.id === id);
      if (!tab) return;
      if (renderedScrollEl) renderedScrollEl.scrollTop = tab.scroll.rendered;
      editorRef?.setScrollTop(tab.scroll.source);
    });
  }

  // Opens `path` in its own tab, or focuses the existing tab for it —
  // matched first on the given path, then again on the canonical path
  // the backend resolves it to (symlinks, relative launch paths).
  async function openPathInTab(path: string) {
    const existing = tabs.find((tab) => tab.source.kind === "file" && tab.source.path === path);
    if (existing) {
      switchToTab(existing.id);
      return;
    }

    const document = await invoke<OpenedDocument>("open_document", { path });

    const resolved = tabs.find(
      (tab) => tab.source.kind === "file" && tab.source.path === document.path,
    );
    if (resolved) {
      switchToTab(resolved.id);
      return;
    }

    openTab({
      source: { kind: "file", path: document.path },
      sourceText: document.content,
      savedText: document.content,
      viewMode: "rendered",
      renderedHtml: convertLocalImageSources(document.html),
      scroll: { rendered: 0, source: 0 },
      conflict: null,
    });
  }

  // Opening a folder leaves every open tab in place — the folder root
  // and the open documents are independent; the explorer just gives
  // you another way to pick what to open next.
  async function openFolderAtPath(path: string) {
    const opened = await invoke<{ path: string }>("open_folder", { path });
    folderRoot = opened.path;
  }

  async function openFileFromExplorer(path: string) {
    errorMessage = null;
    try {
      await openPathInTab(path);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  // Distinct from openFileFromExplorer so a failure can offer a
  // "Remove favorite" action — that affordance makes no sense for the
  // plain folder Explorer's open-failure path.
  async function openFavoriteFile(path: string) {
    errorMessage = null;
    failedFavoritePath = null;
    try {
      await openPathInTab(path);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
      failedFavoritePath = path;
    }
  }

  function closeFolder() {
    folderRoot = null;
  }

  let explorerRef = $state<{
    createFile: () => Promise<void>;
    createFolder: () => Promise<void>;
  } | null>(null);

  async function createFileAtRoot() {
    errorMessage = null;
    try {
      await explorerRef?.createFile();
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async function createFolderAtRoot() {
    errorMessage = null;
    try {
      await explorerRef?.createFolder();
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  // A rename or move completed through the explorer: remap the path
  // of every open tab affected — the renamed/moved file itself, or
  // any file nested under a renamed/moved folder — without touching
  // its content, scroll, or dirty state.
  function handleEntryMoved(fromPath: string, toEntry: FolderEntry) {
    for (const tab of tabs) {
      const remapped = remapDocumentSource(tab.source, fromPath, toEntry.path);
      if (remapped !== tab.source) tab.source = remapped;
    }
  }

  // A delete completed through the explorer: flag any open tab on the
  // deleted file (or nested under a deleted folder) as missing, the
  // same banner an externally deleted file already shows — the
  // buffer stays in the tab, only the disk copy is gone.
  function handleEntryDeleted(path: string) {
    for (const tab of tabs) {
      if (tab.source.kind !== "file") continue;
      if (tab.source.path === path || tab.source.path.startsWith(`${path}/`)) {
        tab.conflict = "missing";
        tab.savedText = null;
      }
    }
  }

  // Keep the backend watcher pointed at the active tab's file.
  // Background tabs are not watched — only the active one, so
  // external-change detection is scoped to what's on screen.
  $effect(() => {
    const path = activeTab?.source.kind === "file" ? activeTab.source.path : null;
    void invoke("watch_document", { path }).catch(() => {
      // A file that cannot be watched still works; changes just are
      // not detected.
    });
  });

  /// Asks what to do with a tab's unsaved changes. Resolved by the modal.
  function confirmLoseChanges(): Promise<"save" | "discard" | "cancel"> {
    return new Promise((resolve) => {
      confirmResolve = (choice) => {
        confirmResolve = null;
        resolve(choice);
      };
    });
  }

  // Prompts to save or discard one tab's unsaved changes. Returns
  // false when the user cancels — the caller should not proceed.
  async function confirmDiscardTab(tab: Tab): Promise<boolean> {
    if (!isTabDirty(tab)) return true;

    confirmTabName = tabTitle(tab);
    const choice = await confirmLoseChanges();
    confirmTabName = null;
    if (choice === "cancel") return false;
    if (choice === "discard") return true;

    try {
      return await saveTab(tab);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
      return false;
    }
  }

  // Saves a tab to its current path; a tab without one asks for a
  // location. `alwaysAsk` is Save As. The native dialog confirms
  // replacing an existing file.
  async function saveTab(tab: Tab, alwaysAsk = false): Promise<boolean> {
    let path = !alwaysAsk && tab.source.kind === "file" ? tab.source.path : null;

    if (!path) {
      path = await save({
        title: "Save Markdown",
        defaultPath: tab.source.kind === "file" ? tabTitle(tab) : `${tabTitle(tab)}.md`,
        filters: [{ name: "Markdown", extensions: MARKDOWN_EXTENSIONS }],
      });
      if (!path) return false;
    }

    await invoke("save_file", { path, content: tab.sourceText });
    const pathChanged = tab.source.kind !== "file" || tab.source.path !== path;
    tab.source = { kind: "file", path };
    tab.savedText = tab.sourceText;
    tab.conflict = null;

    // A new location changes the base directory; relative images and
    // links resolve against it from now on.
    if (pathChanged) tab.renderedHtml = await renderMarkdown(tab.sourceText, path);

    return true;
  }

  function newDocument() {
    openTab({
      source: { kind: "untitled" },
      sourceText: "",
      savedText: null,
      viewMode: "source",
      renderedHtml: "",
      scroll: { rendered: 0, source: 0 },
      conflict: null,
    });
    errorMessage = null;
  }

  async function saveTabAction(tab: Tab, alwaysAsk: boolean) {
    errorMessage = null;
    try {
      await saveTab(tab, alwaysAsk);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  function saveAction() {
    if (activeTab) void saveTabAction(activeTab, false);
  }

  async function closeTab(id: string) {
    const tab = tabs.find((candidate) => candidate.id === id);
    if (!tab) return;
    if (!(await confirmDiscardTab(tab))) return;

    editorRef?.forgetTab(id);

    const wasActive = activeTabId === id;
    const next = wasActive ? nextActiveTabId(tabs, id) : activeTabId;
    tabs = tabs.filter((candidate) => candidate.id !== id);
    if (wasActive) activeTabId = next;
  }

  function reorderTabs(fromIndex: number, toIndex: number) {
    tabs = moveTab(tabs, fromIndex, toIndex);
  }

  async function setActiveViewMode(mode: ViewMode) {
    const tab = activeTab;
    if (!tab) return;

    try {
      // Entering a mode that shows rendered output re-renders the
      // possibly edited source first.
      if (mode !== "source") tab.renderedHtml = await renderMarkdown(tab.sourceText, baseDirFor(tab.source));
      tab.viewMode = mode;
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  function cycleViewMode() {
    if (!activeTab) return;
    const order = ["rendered", "source", "split"] as const;
    void setActiveViewMode(order[(order.indexOf(activeTab.viewMode) + 1) % order.length]);
  }

  // In Split mode edits re-render live, debounced so a keystroke burst
  // renders once. Only the article HTML updates; the editor is never
  // touched, so its selection survives.
  let renderTimer: ReturnType<typeof setTimeout> | undefined;

  function handleEdit(value: string) {
    const tab = activeTab;
    if (!tab) return;

    tab.sourceText = value;
    if (tab.viewMode !== "split") return;

    clearTimeout(renderTimer);
    const tabId = tab.id;
    renderTimer = setTimeout(() => {
      const target = tabs.find((candidate) => candidate.id === tabId);
      if (!target) return;
      renderMarkdown(target.sourceText, baseDirFor(target.source))
        .then((html) => {
          target.renderedHtml = html;
        })
        .catch((error: unknown) => {
          errorMessage = error instanceof Error ? error.message : String(error);
        });
    }, 150);
  }

  async function openFile() {
    if (isOpening) return;

    isOpening = true;
    errorMessage = null;

    try {
      const selectedPath = await open({
        title: "Open Markdown file",
        multiple: false,
        directory: false,
        filters: [
          {
            name: "Markdown",
            extensions: MARKDOWN_EXTENSIONS,
          },
        ],
      });

      if (!selectedPath) return;

      await openPathInTab(selectedPath);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      isOpening = false;
    }
  }

  async function openFolder() {
    if (isOpening) return;

    isOpening = true;
    errorMessage = null;

    try {
      const selectedPath = await open({
        title: "Open Folder",
        multiple: false,
        directory: true,
      });

      if (!selectedPath) return;

      await openFolderAtPath(selectedPath);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      isOpening = false;
    }
  }

  function addActiveDocumentToFavorites() {
    if (activeTab?.source.kind !== "file") return;
    favorites = upsertFavorite(favorites, activeTab.source.path, "file", Date.now());
  }

  async function addFolderToFavorites() {
    try {
      const selectedPath = await open({
        title: "Add Folder to Favorites",
        multiple: false,
        directory: true,
      });

      if (!selectedPath) return;

      favorites = upsertFavorite(favorites, selectedPath, "directory", Date.now());
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async function pasteClipboard() {
    if (isPasting) return;

    isPasting = true;
    errorMessage = null;

    try {
      const copiedFiles = await invoke<string[]>("clipboard_files");

      if (copiedFiles.length > 1) {
        errorMessage = "The clipboard contains multiple files. Copy one Markdown file.";
        return;
      }

      if (copiedFiles.length === 1) {
        const copiedPath = copiedFiles[0];

        if (!isMarkdownPath(copiedPath)) {
          errorMessage = `${fileName(copiedPath)} is not a Markdown file.`;
          return;
        }

        await openPathInTab(copiedPath);
        return;
      }

      const clipboardText = await readText();

      if (clipboardText.length === 0) {
        errorMessage = "The clipboard contains no text.";
        return;
      }

      openTab({
        source: { kind: "clipboard" },
        sourceText: clipboardText,
        savedText: null,
        viewMode: "rendered",
        renderedHtml: await renderMarkdown(clipboardText, null),
        scroll: { rendered: 0, source: 0 },
        conflict: null,
      });
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      isPasting = false;
    }
  }

  async function handleOpenRequest(request: OpenRequest) {
    errorMessage = null;

    try {
      if (request.error) {
        errorMessage = request.error;
      } else if (request.path) {
        await openPathInTab(request.path);
      } else if (request.folderPath) {
        await openFolderAtPath(request.folderPath);
      } else if (request.stdinPath) {
        const stdinDocument = await invoke<StdinDocument>("open_stdin_document", {
          path: request.stdinPath,
        });
        openTab({
          source: { kind: "stdin" },
          sourceText: stdinDocument.content,
          savedText: null,
          viewMode: "rendered",
          renderedHtml: convertLocalImageSources(stdinDocument.html),
          scroll: { rendered: 0, source: 0 },
          conflict: null,
        });
      }
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  async function openDroppedFiles(paths: string[]) {
    errorMessage = null;

    if (paths.length === 0) return;

    if (paths.length > 1) {
      errorMessage = "Multiple files were dropped. Drop one Markdown file.";
      return;
    }

    const droppedPath = paths[0];

    if (!isMarkdownPath(droppedPath)) {
      errorMessage = `${fileName(droppedPath)} is not a Markdown file.`;
      return;
    }

    try {
      await openPathInTab(droppedPath);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  // HTML5 drop events carry no file paths in Tauri; the webview drag-drop
  // event is the only source of absolute paths.
  onMount(() => {
    const unlisten = getCurrentWebview().onDragDropEvent((event) => {
      if (event.payload.type === "enter" || event.payload.type === "over") {
        isDragOver = true;
      } else if (event.payload.type === "leave") {
        isDragOver = false;
      } else if (event.payload.type === "drop") {
        isDragOver = false;
        void openDroppedFiles(event.payload.paths);
      }
    });

    return () => {
      void unlisten.then((stop) => stop());
    };
  });

  // The saved session: every open tab, which one was active, the
  // folder root, and each tab's unsaved edits, view mode, and scroll
  // position. Quit (cmd+Q) is deliberately unguarded (#9), so unsaved
  // edits must survive through here to make quitting lossless.
  type TabSnapshot = {
    source: DocumentSource;
    viewMode: ViewMode;
    sourceText: string;
    savedText: string | null;
    scroll: { rendered: number; source: number };
  };

  type Session = {
    tabs: TabSnapshot[];
    activeIndex: number;
    folderRoot: string | null;
  };

  // Saving starts only after startup settles, so a half-restored state
  // never overwrites the stored session.
  let sessionReady = $state(false);
  let renderedScrollEl = $state<HTMLElement | null>(null);
  let sessionTimer: ReturnType<typeof setTimeout> | undefined;

  function scheduleSessionSave() {
    if (!sessionReady) return;

    clearTimeout(sessionTimer);
    sessionTimer = setTimeout(() => {
      // Refresh the active tab's scroll position in case the debounce
      // fires without a tab switch in between.
      if (activeTab) {
        activeTab.scroll = {
          rendered: renderedScrollEl?.scrollTop ?? 0,
          source: editorRef?.getScrollTop() ?? 0,
        };
      }

      const session: Session | null =
        tabs.length > 0 || folderRoot
          ? {
              tabs: tabs.map((tab) => ({
                source: tab.source,
                viewMode: tab.viewMode,
                sourceText: tab.sourceText,
                savedText: tab.savedText,
                scroll: tab.scroll,
              })),
              activeIndex: Math.max(
                0,
                tabs.findIndex((tab) => tab.id === activeTabId),
              ),
              folderRoot,
            }
          : null;
      void invoke("save_session", { session }).catch(() => {
        // A session that fails to save costs one restore, nothing more.
      });
    }, 300);
  }

  // Tabs, folder, and edits schedule a save; scroll is captured by the
  // window listener below.
  $effect(() => {
    void [tabs, folderRoot];
    scheduleSessionSave();
  });

  // Favorites persist to their own favorites.json, independent of the
  // session — they don't touch tabs or folderRoot, so there's no
  // ordering dependency on restoreSession(). Saving is gated the same
  // way session saves are: loading sets favoritesReady only once the
  // load resolves, so a save never fires before it.
  let favoritesTimer: ReturnType<typeof setTimeout> | undefined;

  function scheduleFavoritesSave() {
    if (!favoritesReady) return;

    clearTimeout(favoritesTimer);
    favoritesTimer = setTimeout(() => {
      void invoke("save_favorites", { favorites }).catch(() => {
        // Favorites that fail to save cost one restore, nothing more.
      });
    }, 300);
  }

  $effect(() => {
    void favorites;
    scheduleFavoritesSave();
  });

  onMount(() => {
    void (async () => {
      try {
        const loaded = await invoke<FavoriteEntry[] | null>("load_favorites");
        if (loaded) favorites = loaded;
      } catch {
        // Start empty.
      } finally {
        favoritesReady = true;
      }
    })();
  });

  // Scroll events do not bubble but are observable in the capture
  // phase, covering the rendered pane and the editor alike.
  onMount(() => {
    const handler = () => scheduleSessionSave();
    window.addEventListener("scroll", handler, { capture: true, passive: true });
    return () => window.removeEventListener("scroll", handler, { capture: true });
  });

  async function restoreSession() {
    const session = await invoke<Session | null>("load_session");
    if (!session) return;

    if (session.folderRoot) {
      try {
        await openFolderAtPath(session.folderRoot);
      } catch {
        // The folder is gone or unreadable: fall back to the empty
        // state.
        folderRoot = null;
      }
    }

    if (!session.tabs || session.tabs.length === 0) return;

    const restored: Tab[] = [];
    for (const snapshot of session.tabs) {
      try {
        if (snapshot.source.kind === "file") {
          const document = await invoke<OpenedDocument>("open_document", {
            path: snapshot.source.path,
          });
          const diskContent = document.content;
          const sourceText = snapshot.sourceText;

          // The stored buffer differs from disk: keep the unsaved
          // edits. When disk also moved on since the last run, the
          // conflict banner offers the reload.
          const conflict: Tab["conflict"] =
            sourceText !== diskContent &&
            snapshot.savedText !== null &&
            snapshot.savedText !== diskContent
              ? "conflict"
              : null;

          restored.push({
            id: crypto.randomUUID(),
            source: { kind: "file", path: document.path },
            sourceText,
            savedText: snapshot.savedText,
            viewMode: snapshot.viewMode ?? "rendered",
            renderedHtml: await renderMarkdown(sourceText, document.path),
            scroll: snapshot.scroll ?? { rendered: 0, source: 0 },
            conflict,
          });
        } else if (snapshot.sourceText) {
          // Pathless documents (clipboard, stdin, untitled) restore
          // from the stored buffer alone; an empty one is not worth
          // showing.
          restored.push({
            id: crypto.randomUUID(),
            source: snapshot.source,
            sourceText: snapshot.sourceText,
            savedText: snapshot.savedText,
            viewMode: snapshot.viewMode ?? "rendered",
            renderedHtml: await renderMarkdown(snapshot.sourceText, null),
            scroll: snapshot.scroll ?? { rendered: 0, source: 0 },
            conflict: null,
          });
        }
      } catch {
        // That tab's file is gone or unreadable: drop just that tab
        // rather than failing the whole restore.
      }
    }

    if (restored.length === 0) return;

    tabs = restored;
    const activeIndex = Math.min(Math.max(session.activeIndex ?? 0, 0), restored.length - 1);
    activeTabId = restored[activeIndex].id;

    requestAnimationFrame(() => {
      const tab = activeTab;
      if (!tab) return;
      if (renderedScrollEl) renderedScrollEl.scrollTop = tab.scroll.rendered;
      editorRef?.setScrollTop(tab.scroll.source);
    });
  }

  // Open a document passed on the command line (`markive path.md`),
  // falling back to the previous session.
  void (async () => {
    try {
      await listen<OpenRequest>("open-document", (event) => void handleOpenRequest(event.payload));
      const request = await invoke<OpenRequest | null>("launch_document");
      if (request) {
        await handleOpenRequest(request);
      } else {
        await restoreSession();
      }
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      sessionReady = true;
    }
  })();

  // External changes to the active tab's file, reported by the
  // backend watcher (only the active tab is watched).
  async function handleFileChange(kind: string) {
    const tab = activeTab;
    if (!tab || tab.source.kind !== "file") return;

    if (kind === "removed") {
      tab.conflict = "missing";
      // The disk copy is gone; the buffer is the only copy and needs
      // saving again.
      tab.savedText = null;
      return;
    }

    if (isTabDirty(tab)) {
      tab.conflict = "conflict";
      return;
    }

    try {
      await reloadTabContent(tab.id);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  onMount(() => {
    const unlisten = listen<{ kind: string }>("document-file-changed", (event) => {
      void handleFileChange(event.payload.kind);
    });
    return () => {
      void unlisten.then((stop) => stop());
    };
  });

  // Re-reads a file tab's content from disk in place, replacing its
  // buffer without changing its identity or position among the tabs.
  async function reloadTabContent(tabId: string) {
    const tab = tabs.find((candidate) => candidate.id === tabId);
    if (!tab || tab.source.kind !== "file") return;

    const document = await invoke<OpenedDocument>("open_document", { path: tab.source.path });
    tab.sourceText = document.content;
    tab.savedText = document.content;
    tab.renderedHtml = convertLocalImageSources(document.html);
    tab.conflict = null;
  }

  async function reloadFromDisk() {
    if (!activeTab || activeTab.source.kind !== "file") return;
    try {
      await reloadTabContent(activeTab.id);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  // The webview must never navigate: every link click is intercepted
  // and routed by target type. Registered on window in the capture
  // phase to run before Tauri's own document-level click handling,
  // which otherwise navigates the webview.
  function handleLinkClick(event: MouseEvent) {
    const anchor = (event.target as Element).closest("a");
    if (!anchor) return;

    event.preventDefault();
    event.stopImmediatePropagation();

    const href = anchor.getAttribute("href");
    if (!href) return;

    void openLink(href);
  }

  onMount(() => {
    window.addEventListener("click", handleLinkClick, { capture: true });
    return () => window.removeEventListener("click", handleLinkClick, { capture: true });
  });

  // Native menu items forward here; the shortcuts they declare are
  // consumed by the menu, so these actions have no keydown handlers.
  function handleMenuAction(action: string) {
    switch (action) {
      case "new":
        newDocument();
        break;
      case "open":
        void openFile();
        break;
      case "open-folder":
        void openFolder();
        break;
      case "quick-open":
        openQuickOpen();
        break;
      case "find-in-files":
        openSearchPanel();
        break;
      case "undo":
        editorRef?.undoEdit();
        break;
      case "redo":
        editorRef?.redoEdit();
        break;
      case "save":
        saveAction();
        break;
      case "save-as":
        if (activeTab) void saveTabAction(activeTab, true);
        break;
      case "find":
        openFind();
        break;
      case "view-rendered":
        void setActiveViewMode("rendered");
        break;
      case "view-source":
        void setActiveViewMode("source");
        break;
      case "view-split":
        void setActiveViewMode("split");
        break;
      case "close-tab":
        if (activeTabId) void closeTab(activeTabId);
        break;
      case "close-window":
        void getCurrentWindow().close();
        break;
      case "theme-light":
        themePreference = "light";
        break;
      case "theme-dark":
        themePreference = "dark";
        break;
      case "theme-system":
        themePreference = "system";
        break;
      case "settings":
        settingsOpen = true;
        break;
      case "add-to-favorites":
        addActiveDocumentToFavorites();
        break;
      case "add-folder-to-favorites":
        void addFolderToFavorites();
        break;
      case "show-favorites":
        showFavorites = !showFavorites;
        break;
    }
  }

  onMount(() => {
    const unlisten = listen<string>("menu-action", (event) => {
      handleMenuAction(event.payload);
    });
    return () => {
      void unlisten.then((stop) => stop());
    };
  });

  // Menu enabled/checked state follows the active tab.
  $effect(() => {
    void invoke("set_menu_state", {
      hasDocument: activeTab !== undefined,
      hasFolder: folderRoot !== null,
      hasFileDocument: activeTab?.source.kind === "file",
      viewMode: activeTab?.viewMode ?? "rendered",
      theme: themePreference,
      showFavorites,
    }).catch(() => {
      // A menu that lags the document state is not worth surfacing.
    });
  });

  // The System preference follows macOS appearance changes live.
  onMount(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const update = (event: MediaQueryListEvent) => {
      systemDark = event.matches;
    };
    media.addEventListener("change", update);
    return () => media.removeEventListener("change", update);
  });

  $effect(() => {
    document.documentElement.classList.toggle("dark", isDark);
    localStorage.setItem("markive-theme", themePreference);
  });

  // The window chrome (title bar) follows the preference; null returns
  // it to the system appearance.
  $effect(() => {
    void getCurrentWindow()
      .setTheme(themePreference === "system" ? null : themePreference)
      .catch(() => {
        // Chrome that lags the content theme is not worth surfacing.
      });
  });

  // Closing the window guards every dirty tab's unsaved changes. Quit
  // (cmd+Q) is deliberately unguarded, following the macOS document
  // model; #15 makes quit lossless by restoring the session including
  // unsaved edits.
  onMount(() => {
    const unlistenClose = getCurrentWindow().onCloseRequested(async (event) => {
      for (const tab of tabs) {
        if (!(await confirmDiscardTab(tab))) {
          event.preventDefault();
          return;
        }
      }
    });

    return () => {
      void unlistenClose.then((stop) => stop());
    };
  });

  async function openLink(href: string) {
    errorMessage = null;

    try {
      if (href.startsWith("#")) {
        const target = document.getElementById(decodeURIComponent(href.slice(1)));
        target?.scrollIntoView({ behavior: "smooth", block: "start" });
        return;
      }

      if (href.startsWith("http://") || href.startsWith("https://")) {
        await openUrl(href);
        return;
      }

      if (href.startsWith("/")) {
        const path = decodeURIComponent(href);

        if (!isMarkdownPath(path)) {
          errorMessage = `${fileName(path)} is not a Markdown file.`;
          return;
        }

        await openPathInTab(path);
        return;
      }

      errorMessage = `Blocked link: ${href}`;
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  // Shortcuts without a native menu item. Everything the menu declares
  // (⌘N, ⌘O, ⌘S, ⇧⌘S, ⌘F, ⌘1–3, ⌘W, ⇧⌘W) arrives as a menu-action
  // event instead.
  function handleKeydown(event: KeyboardEvent) {
    if (event.key === "Escape" && settingsOpen) {
      settingsOpen = false;
      return;
    }

    if (event.key === "Escape" && confirmResolve) {
      confirmResolve("cancel");
      return;
    }

    if (!(event.metaKey || event.ctrlKey)) return;

    const key = event.key.toLowerCase();

    if (key === "g" && findOpen) {
      event.preventDefault();
      findStep(event.shiftKey ? -1 : 1);
      return;
    }

    if (key === "e" && activeTab) {
      event.preventDefault();
      cycleViewMode();
      return;
    }

    // Inside the editor, ⌘V pastes text; outside it opens the
    // clipboard as a document.
    const inEditor = (event.target as Element).closest(".cm-editor") !== null;

    if (key === "v" && !inEditor) {
      event.preventDefault();
      void pasteClipboard();
    }
  }
</script>

<svelte:head>
  <title>{isDirty ? `• ${documentName}` : documentName}</title>
</svelte:head>

<svelte:window onkeydown={handleKeydown} />

<div class="flex min-h-screen bg-background text-foreground">
  {#if showFavorites}
    <FavoritesSidebar
      {favorites}
      onOpenFile={openFavoriteFile}
      onRemove={(path) => (favorites = removeFavorite(favorites, path))}
      onClose={() => (showFavorites = false)}
    />
  {/if}
  {#if folderRoot}
    <aside class="flex w-64 shrink-0 flex-col border-r border-border">
      <div class="flex items-center justify-between gap-2 border-b border-border px-2 py-2">
        <div class="min-w-0">
          <p class="truncate text-sm font-medium" title={folderRoot}>
            {folderRoot.split(/[\\/]/).pop() ?? folderRoot}
          </p>
          <p class="truncate text-xs text-muted-foreground" title={folderRoot}>{folderRoot}</p>
        </div>
        <div class="flex shrink-0 items-center gap-0.5">
          <Button variant="ghost" size="icon-sm" aria-label="New file" onclick={() => void createFileAtRoot()}>
            <FilePlus2 aria-hidden="true" class="size-3.5" />
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label="New folder"
            onclick={() => void createFolderAtRoot()}
          >
            <FolderPlus aria-hidden="true" class="size-3.5" />
          </Button>
          <Button
            variant="ghost"
            size="icon-sm"
            aria-label={showHiddenFiles ? "Hide hidden files" : "Show hidden files"}
            aria-pressed={showHiddenFiles}
            onclick={() => (showHiddenFiles = !showHiddenFiles)}
          >
            {#if showHiddenFiles}
              <EyeOff aria-hidden="true" class="size-3.5" />
            {:else}
              <Eye aria-hidden="true" class="size-3.5" />
            {/if}
          </Button>
          <Button variant="ghost" size="icon-sm" aria-label="Close folder" onclick={closeFolder}>
            <X aria-hidden="true" class="size-3.5" />
          </Button>
        </div>
      </div>
      <Explorer
        bind:this={explorerRef}
        rootPath={folderRoot}
        showHidden={showHiddenFiles}
        activePath={activeTab?.source.kind === "file" ? activeTab.source.path : null}
        isActiveDirty={isDirty}
        onOpenFile={openFileFromExplorer}
        onEntryMoved={handleEntryMoved}
        onEntryDeleted={handleEntryDeleted}
        onError={(message) => (errorMessage = message)}
      />
    </aside>
  {/if}
  <main
    class={`grid min-w-0 flex-1 grid-rows-[auto_2.75rem_auto_auto_1fr] ${isDragOver ? "ring-2 ring-inset ring-ring" : ""}`}
  >
  {#if tabs.length > 0}
    <TabBar {tabs} {activeTabId} onSelect={switchToTab} onClose={closeTab} onReorder={reorderTabs} />
  {:else}
    <div></div>
  {/if}

  <header class="path-rail flex items-center justify-between gap-4 border-b border-border px-4">
    <div class="flex min-w-0 items-center gap-2 font-mono text-xs text-muted-foreground">
      <FileText aria-hidden="true" class="size-3.5 shrink-0" strokeWidth={1.75} />
      <span class="truncate">{sourceLabel}</span>
      {#if isDirty}
        <span class="shrink-0 text-foreground" title="Unsaved changes" aria-label="Unsaved changes">•</span>
      {/if}
    </div>
    {#if activeTab}
      <div class="flex items-center gap-1">
        <div class="mr-2 flex items-center rounded-md border border-border p-0.5" role="group" aria-label="View mode">
          <Button
            variant={activeTab.viewMode === "rendered" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={activeTab.viewMode === "rendered"}
            onclick={() => void setActiveViewMode("rendered")}
          >
            <Eye data-icon="inline-start" aria-hidden="true" />
            Rendered
          </Button>
          <Button
            variant={activeTab.viewMode === "source" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={activeTab.viewMode === "source"}
            onclick={() => void setActiveViewMode("source")}
          >
            <Code data-icon="inline-start" aria-hidden="true" />
            Source
          </Button>
          <Button
            variant={activeTab.viewMode === "split" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={activeTab.viewMode === "split"}
            onclick={() => void setActiveViewMode("split")}
          >
            <Columns2 data-icon="inline-start" aria-hidden="true" />
            Split
          </Button>
        </div>
        <Button variant="ghost" size="sm" onclick={newDocument}>
          <FilePlus data-icon="inline-start" aria-hidden="true" />
          New
        </Button>
        <Button variant="ghost" size="sm" onclick={saveAction} disabled={!isDirty}>
          <Save data-icon="inline-start" aria-hidden="true" />
          Save
        </Button>
        <Button variant="ghost" size="sm" onclick={pasteClipboard} disabled={isPasting}>
          <ClipboardPaste data-icon="inline-start" aria-hidden="true" />
          Paste
        </Button>
        <Button variant="ghost" size="sm" onclick={openFile} disabled={isOpening}>
          <FolderOpen data-icon="inline-start" aria-hidden="true" />
          Open
        </Button>
      </div>
    {/if}
  </header>

  {#if activeTab?.conflict}
    <div
      class="flex items-center justify-between gap-4 border-b border-border bg-secondary px-4 py-2"
      role="alert"
    >
      <p class="min-w-0 truncate text-sm">
        {activeTab.conflict === "missing"
          ? "The file was deleted or moved on disk. Your text is only in this window until you save it."
          : "The file changed on disk while you have unsaved edits."}
      </p>
      <div class="flex shrink-0 items-center gap-1">
        {#if activeTab.conflict === "conflict"}
          <Button variant="outline" size="sm" onclick={() => void reloadFromDisk()}>
            Reload from Disk
          </Button>
        {/if}
        <Button variant="outline" size="sm" onclick={() => activeTab && void saveTabAction(activeTab, true)}>
          Save As
        </Button>
        <Button variant="ghost" size="sm" onclick={() => activeTab && (activeTab.conflict = null)}>
          Keep Editing
        </Button>
      </div>
    </div>
  {:else}
    <div></div>
  {/if}

  {#if findOpen}
    <div class="flex items-center gap-2 border-b border-border bg-secondary px-4 py-2" role="search">
      <SearchIcon aria-hidden="true" class="size-3.5 shrink-0 text-muted-foreground" />
      <input
        bind:this={findInput}
        bind:value={findQuery}
        onkeydown={handleFindKeydown}
        type="text"
        placeholder="Find in document"
        aria-label="Find in document"
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
        class="w-64 rounded-md border border-input bg-background px-2 py-1 text-sm outline-none focus:ring-1 focus:ring-ring"
      />
      <span class="text-xs text-muted-foreground" role="status">
        {#if findQuery.length === 0}
          &nbsp;
        {:else if findCount === 0}
          No matches
        {:else if activeTab?.viewMode === "rendered"}
          {findIndex + 1} of {findCount}
        {:else}
          {findCount} {findCount === 1 ? "match" : "matches"}
        {/if}
      </span>
      <div class="ml-auto flex items-center gap-1">
        <Button
          variant="ghost"
          size="sm"
          aria-label="Previous match"
          onclick={() => findStep(-1)}
          disabled={findCount === 0}
        >
          <ChevronUp aria-hidden="true" />
        </Button>
        <Button
          variant="ghost"
          size="sm"
          aria-label="Next match"
          onclick={() => findStep(1)}
          disabled={findCount === 0}
        >
          <ChevronDown aria-hidden="true" />
        </Button>
        <Button variant="ghost" size="sm" onclick={closeFind} aria-label="Close find">
          <X aria-hidden="true" />
        </Button>
      </div>
    </div>
  {:else}
    <div></div>
  {/if}

  {#if activeTab}
    <!-- The editor stays mounted across every view mode so each tab's
         CodeMirror selection and undo history survive switching away
         and back — only visibility and layout change. -->
    <section
      class="grid min-h-0 grid-rows-[auto_1fr] bg-card"
      aria-label={`${activeTab.viewMode === "split" ? "Split view" : activeTab.viewMode === "source" ? "Source" : "Rendered"} of ${documentName}`}
    >
      {#if errorMessage}
        <p
          class="flex items-center justify-between gap-4 border-b border-border px-8 py-2 text-sm text-destructive"
          role="alert"
        >
          <span class="min-w-0 truncate">{errorMessage}</span>
          {#if failedFavoritePath}
            <Button
              variant="outline"
              size="sm"
              onclick={() => {
                favorites = removeFavorite(favorites, failedFavoritePath!);
                errorMessage = null;
                failedFavoritePath = null;
              }}
            >
              Remove favorite
            </Button>
          {/if}
        </p>
      {:else}
        <div></div>
      {/if}
      <div class={`grid min-h-0 ${activeTab.viewMode === "split" ? "grid-cols-2" : "grid-cols-1"}`}>
        <div
          class={`min-h-0 ${activeTab.viewMode === "split" ? "border-r border-border" : ""} ${activeTab.viewMode === "rendered" ? "hidden" : ""}`}
        >
          <Editor
            bind:this={editorRef}
            tabId={activeTab.id}
            value={activeTab.sourceText}
            dark={isDark}
            fontSize={editorFontSize}
            lineWrap={preferences.lineWrap}
            onchange={handleEdit}
          />
        </div>
        {#if activeTab.viewMode !== "source"}
          <!-- Focusable so the preview scrolls with arrow keys alone —
               the WAI pattern for scrollable regions, which this a11y
               rule does not model. -->
          <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
          <div
            class="min-h-0 overflow-auto focus-visible:outline-2 focus-visible:outline-ring"
            bind:this={renderedScrollEl}
            tabindex="0"
            role="region"
            aria-label="Rendered preview"
          >
            <article class="markdown mx-auto w-full px-8 py-14" style={`max-width: ${proseWidth}`}>
              {@html findResult.html}
            </article>
          </div>
        {/if}
      </div>
    </section>
  {:else if folderRoot}
    <section class="grid place-items-center px-6">
      <div class="max-w-sm text-center">
        <p class="font-mono text-xs tracking-wide text-muted-foreground">MARKIVE</p>
        <h1 class="mt-4 text-balance text-2xl font-medium tracking-tight">Pick a file to open.</h1>
        <p class="mt-2 text-pretty text-sm leading-6 text-muted-foreground">
          Select a Markdown file in the sidebar, or open one from disk.
        </p>
        <div class="mt-6 flex justify-center gap-2">
          <Button variant="outline" size="lg" onclick={newDocument}>
            <FilePlus data-icon="inline-start" aria-hidden="true" />
            New
          </Button>
          <Button size="lg" onclick={openFile} disabled={isOpening}>
            <FolderOpen data-icon="inline-start" aria-hidden="true" />
            {isOpening ? "Opening…" : "Open file"}
          </Button>
        </div>
        {#if errorMessage}
          <p class="mt-4 text-sm text-destructive" role="alert">{errorMessage}</p>
          {#if failedFavoritePath}
            <Button
              variant="outline"
              size="sm"
              class="mt-2"
              onclick={() => {
                favorites = removeFavorite(favorites, failedFavoritePath!);
                errorMessage = null;
                failedFavoritePath = null;
              }}
            >
              Remove favorite
            </Button>
          {/if}
        {/if}
      </div>
    </section>
  {:else}
    <section class="grid place-items-center px-6">
      <div class="max-w-sm text-center">
        <p class="font-mono text-xs tracking-wide text-muted-foreground">MARKIVE</p>
        <h1 class="mt-4 text-balance text-2xl font-medium tracking-tight">
          Open a Markdown file.
        </h1>
        <p class="mt-2 text-pretty text-sm leading-6 text-muted-foreground">
          Open a file from disk, or paste Markdown without creating one.
        </p>
        <div class="mt-6 flex flex-wrap justify-center gap-2">
          <Button variant="outline" size="lg" onclick={newDocument}>
            <FilePlus data-icon="inline-start" aria-hidden="true" />
            New
          </Button>
          <Button size="lg" onclick={openFile} disabled={isOpening}>
            <FolderOpen data-icon="inline-start" aria-hidden="true" />
            {isOpening ? "Opening…" : "Open file"}
          </Button>
          <Button variant="outline" size="lg" onclick={openFolder} disabled={isOpening}>
            <FolderOpen data-icon="inline-start" aria-hidden="true" />
            Open folder
          </Button>
          <Button variant="outline" size="lg" onclick={pasteClipboard} disabled={isPasting}>
            <ClipboardPaste data-icon="inline-start" aria-hidden="true" />
            {isPasting ? "Pasting…" : "Paste clipboard"}
          </Button>
        </div>
        {#if errorMessage}
          <p class="mt-4 text-sm text-destructive" role="alert">{errorMessage}</p>
          {#if failedFavoritePath}
            <Button
              variant="outline"
              size="sm"
              class="mt-2"
              onclick={() => {
                favorites = removeFavorite(favorites, failedFavoritePath!);
                errorMessage = null;
                failedFavoritePath = null;
              }}
            >
              Remove favorite
            </Button>
          {/if}
        {/if}
      </div>
    </section>
  {/if}
  </main>
</div>

{#if quickOpenOpen && folderRoot}
  <QuickOpen
    rootPath={folderRoot}
    includeHidden={showHiddenFiles}
    onOpenFile={openFileFromQuickOpen}
    onClose={() => (quickOpenOpen = false)}
  />
{/if}

{#if searchPanelOpen && folderRoot}
  <SearchPanel
    rootPath={folderRoot}
    includeHidden={showHiddenFiles}
    onOpenMatch={openSearchMatch}
    onClose={() => (searchPanelOpen = false)}
  />
{/if}

{#if confirmResolve}
  <div
    class="fixed inset-0 z-50 grid place-items-center bg-black/40"
    role="alertdialog"
    aria-modal="true"
    aria-labelledby="confirm-title"
  >
    <div class="w-full max-w-sm rounded-lg border border-border bg-background p-6 shadow-lg">
      <h2 id="confirm-title" class="text-base font-medium">Unsaved changes</h2>
      <p class="mt-2 text-sm text-muted-foreground">
        {confirmTabName} has unsaved changes. Save them before continuing?
      </p>
      <div class="mt-6 flex justify-end gap-2">
        <Button variant="ghost" size="sm" onclick={() => confirmResolve?.("cancel")}>
          Cancel
        </Button>
        <Button variant="outline" size="sm" onclick={() => confirmResolve?.("discard")}>
          Discard
        </Button>
        <Button size="sm" onclick={() => confirmResolve?.("save")} {@attach focusOnMount}>
          Save
        </Button>
      </div>
    </div>
  </div>
{/if}

{#if settingsOpen}
  <div
    class="fixed inset-0 z-50 grid place-items-center bg-black/40"
    role="dialog"
    aria-modal="true"
    aria-labelledby="settings-title"
  >
    <div class="w-full max-w-sm rounded-lg border border-border bg-background p-6 shadow-lg">
      <h2 id="settings-title" class="text-base font-medium">Settings</h2>
      <div class="mt-4 grid gap-4 text-sm">
        <label class="grid gap-1.5">
          <span class="text-muted-foreground">Appearance</span>
          <select
            bind:value={themePreference}
            class="rounded-md border border-input bg-background px-2 py-1.5"
            {@attach focusOnMount}
          >
            <option value="system">System</option>
            <option value="light">Light</option>
            <option value="dark">Dark</option>
          </select>
        </label>
        <label class="grid gap-1.5">
          <span class="text-muted-foreground">Prose width</span>
          <select
            bind:value={preferences.proseWidth}
            class="rounded-md border border-input bg-background px-2 py-1.5"
          >
            <option value="narrow">Narrow</option>
            <option value="default">Default</option>
            <option value="wide">Wide</option>
          </select>
        </label>
        <label class="grid gap-1.5">
          <span class="text-muted-foreground">Editor font size</span>
          <input
            type="number"
            min="11"
            max="24"
            bind:value={preferences.editorFontSize}
            class="rounded-md border border-input bg-background px-2 py-1.5"
          />
        </label>
        <label class="flex items-center gap-2">
          <input type="checkbox" bind:checked={preferences.lineWrap} />
          <span>Wrap long lines in the editor</span>
        </label>
        <div class="grid gap-1.5 border-t border-border pt-4">
          <span class="text-muted-foreground">Command line</span>
          <div>
            <Button variant="outline" size="sm" onclick={() => void installCli()}>
              Install Command Line Tool
            </Button>
          </div>
          {#if cliStatus}
            <p class="text-xs text-muted-foreground" role="status">{cliStatus}</p>
          {/if}
        </div>
      </div>
      <div class="mt-6 flex justify-end">
        <Button size="sm" onclick={() => (settingsOpen = false)}>Done</Button>
      </div>
    </div>
  </div>
{/if}
