<script lang="ts">
  import { ClipboardPaste, Code, Columns2, Eye, FileText, FolderOpen, Save } from "@lucide/svelte";
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

  type OpenedDocument = {
    path: string;
    html: string;
    content: string;
  };

  type StdinDocument = {
    html: string;
    content: string;
  };

  type DocumentSource =
    | { kind: "file"; path: string }
    | { kind: "clipboard" }
    | { kind: "stdin" };

  type OpenRequest = { path: string | null; stdinPath: string | null; error: string | null };

  const MARKDOWN_EXTENSIONS = ["md", "markdown", "mdown", "mkd"];

  let documentSource = $state<DocumentSource | null>(null);
  let renderedHtml = $state("");
  let sourceText = $state("");
  // Content as last loaded or saved; null for documents that never
  // had a file (clipboard, stdin), which stay dirty until saved.
  let savedText = $state<string | null>(null);
  let viewMode = $state<"rendered" | "source" | "split">("rendered");
  let errorMessage = $state<string | null>(null);
  let confirmResolve = $state<((choice: "save" | "discard" | "cancel") => void) | null>(null);

  let isDirty = $derived(
    documentSource !== null && (savedText === null || sourceText !== savedText),
  );
  let isOpening = $state(false);
  let isPasting = $state(false);
  let isDragOver = $state(false);

  // The open document's directory; relative image and link targets in
  // edited source resolve against it.
  let baseDir = $derived(
    documentSource?.kind === "file"
      ? (documentSource.path.slice(0, documentSource.path.lastIndexOf("/")) ?? null)
      : null,
  );

  let documentName = $derived(
    documentSource?.kind === "file"
      ? (documentSource.path.split(/[\\/]/).pop() ?? "Markive")
      : documentSource?.kind === "clipboard"
        ? "Clipboard"
        : documentSource?.kind === "stdin"
          ? "stdin"
          : "Markive",
  );
  let sourceLabel = $derived(
    documentSource?.kind === "file"
      ? documentSource.path
      : documentSource?.kind === "clipboard"
        ? "Clipboard"
        : documentSource?.kind === "stdin"
          ? "Piped from stdin"
          : "No file open",
  );

  function fileName(path: string): string {
    return path.split(/[\\/]/).pop() ?? path;
  }

  function isMarkdownPath(path: string): boolean {
    const extension = fileName(path).split(".").pop()?.toLowerCase() ?? "";
    return MARKDOWN_EXTENSIONS.includes(extension);
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

  async function openDocumentAtPath(path: string) {
    const document = await invoke<OpenedDocument>("open_document", { path });

    documentSource = { kind: "file", path: document.path };
    renderedHtml = convertLocalImageSources(document.html);
    sourceText = document.content;
    savedText = document.content;
    viewMode = "rendered";
  }

  /// Asks what to do with unsaved changes. Resolved by the modal.
  function confirmLoseChanges(): Promise<"save" | "discard" | "cancel"> {
    return new Promise((resolve) => {
      confirmResolve = (choice) => {
        confirmResolve = null;
        resolve(choice);
      };
    });
  }

  async function saveCurrentDocument(): Promise<boolean> {
    let path = documentSource?.kind === "file" ? documentSource.path : null;

    if (!path) {
      path = await save({
        title: "Save Markdown",
        filters: [{ name: "Markdown", extensions: MARKDOWN_EXTENSIONS }],
      });
      if (!path) return false;
    }

    await invoke("save_file", { path, content: sourceText });
    documentSource = { kind: "file", path };
    savedText = sourceText;
    return true;
  }

  async function saveAction() {
    if (!documentSource) return;

    errorMessage = null;
    try {
      await saveCurrentDocument();
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  // Gate for every action that replaces or closes the document.
  async function canDiscardDocument(): Promise<boolean> {
    if (!isDirty) return true;

    const choice = await confirmLoseChanges();
    if (choice === "cancel") return false;
    if (choice === "discard") return true;

    try {
      return await saveCurrentDocument();
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
      return false;
    }
  }

  async function renderCurrentSource() {
    const html = await invoke<string>("render_source", {
      markdown: sourceText,
      baseDir,
    });
    renderedHtml = convertLocalImageSources(html);
  }

  // In Split mode edits re-render live, debounced so a keystroke burst
  // renders once. Only the article HTML updates; the editor is never
  // touched, so its selection survives.
  let renderTimer: ReturnType<typeof setTimeout> | undefined;

  function handleEdit(value: string) {
    sourceText = value;

    if (viewMode !== "split") return;

    clearTimeout(renderTimer);
    renderTimer = setTimeout(() => {
      renderCurrentSource().catch((error: unknown) => {
        errorMessage = error instanceof Error ? error.message : String(error);
      });
    }, 150);
  }

  async function setViewMode(mode: typeof viewMode) {
    if (!documentSource) return;

    try {
      // Entering a mode that shows rendered output re-renders the
      // possibly edited source first.
      if (mode !== "source") await renderCurrentSource();
      viewMode = mode;
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  function cycleViewMode() {
    const order = ["rendered", "source", "split"] as const;
    void setViewMode(order[(order.indexOf(viewMode) + 1) % order.length]);
  }

  async function openFile() {
    if (isOpening) return;
    if (!(await canDiscardDocument())) return;

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

      await openDocumentAtPath(selectedPath);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      isOpening = false;
    }
  }

  async function pasteClipboard() {
    if (isPasting) return;
    if (!(await canDiscardDocument())) return;

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

        await openDocumentAtPath(copiedPath);
        return;
      }

      const clipboardText = await readText();

      if (clipboardText.length === 0) {
        errorMessage = "The clipboard contains no text.";
        return;
      }

      const html = await invoke<string>("render_source", {
        markdown: clipboardText,
        baseDir: null,
      });

      documentSource = { kind: "clipboard" };
      renderedHtml = convertLocalImageSources(html);
      sourceText = clipboardText;
      savedText = null;
      viewMode = "rendered";
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
      } else if (!(await canDiscardDocument())) {
        // Keep the current document; a stdin temp file left behind in
        // the temp dir is cleaned up by the OS.
      } else if (request.path) {
        await openDocumentAtPath(request.path);
      } else if (request.stdinPath) {
        const stdinDocument = await invoke<StdinDocument>("open_stdin_document", {
          path: request.stdinPath,
        });
        documentSource = { kind: "stdin" };
        renderedHtml = convertLocalImageSources(stdinDocument.html);
        sourceText = stdinDocument.content;
        savedText = null;
        viewMode = "rendered";
      }
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }
  async function openDroppedFiles(paths: string[]) {
    errorMessage = null;

    if (paths.length === 0) return;
    if (!(await canDiscardDocument())) return;

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
      await openDocumentAtPath(droppedPath);
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

  // Open a document passed on the command line (`markive path.md`).
  void (async () => {
    try {
      await listen<OpenRequest>("open-document", (event) => void handleOpenRequest(event.payload));
      const request = await invoke<OpenRequest | null>("launch_document");
      if (request) await handleOpenRequest(request);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  })();

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

  // Closing the window guards unsaved changes. Quit (cmd+Q) is
  // deliberately unguarded, following the macOS document model; #15
  // makes quit lossless by restoring the session including unsaved
  // edits.
  onMount(() => {
    const unlistenClose = getCurrentWindow().onCloseRequested(async (event) => {
      if (!(await canDiscardDocument())) {
        event.preventDefault();
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

        await openDocumentAtPath(path);
        return;
      }

      errorMessage = `Blocked link: ${href}`;
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
  }

  function handleKeydown(event: KeyboardEvent) {
    if (!(event.metaKey || event.ctrlKey)) return;

    const key = event.key.toLowerCase();

    if (key === "s" && documentSource) {
      event.preventDefault();
      void saveAction();
      return;
    }

    if (key === "e" && documentSource) {
      event.preventDefault();
      cycleViewMode();
      return;
    }

    if (documentSource && (key === "1" || key === "2" || key === "3")) {
      event.preventDefault();
      void setViewMode((["rendered", "source", "split"] as const)[Number(key) - 1]);
      return;
    }

    // Inside the editor, ⌘V pastes text and ⌘O is the only global
    // shortcut that still applies.
    const inEditor = (event.target as Element).closest(".cm-editor") !== null;

    if (key === "o") {
      event.preventDefault();
      void openFile();
    }

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

<main
  class={`grid min-h-screen grid-rows-[2.75rem_1fr] bg-background text-foreground ${isDragOver ? "ring-2 ring-inset ring-ring" : ""}`}
>
  <header class="path-rail flex items-center justify-between gap-4 border-b border-border px-4">
    <div class="flex min-w-0 items-center gap-2 font-mono text-xs text-muted-foreground">
      <FileText aria-hidden="true" class="size-3.5 shrink-0" strokeWidth={1.75} />
      <span class="truncate">{sourceLabel}</span>
      {#if isDirty}
        <span class="shrink-0 text-foreground" title="Unsaved changes" aria-label="Unsaved changes">•</span>
      {/if}
    </div>
    {#if documentSource}
      <div class="flex items-center gap-1">
        <div class="mr-2 flex items-center rounded-md border border-border p-0.5" role="group" aria-label="View mode">
          <Button
            variant={viewMode === "rendered" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={viewMode === "rendered"}
            onclick={() => void setViewMode("rendered")}
          >
            <Eye data-icon="inline-start" aria-hidden="true" />
            Rendered
          </Button>
          <Button
            variant={viewMode === "source" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={viewMode === "source"}
            onclick={() => void setViewMode("source")}
          >
            <Code data-icon="inline-start" aria-hidden="true" />
            Source
          </Button>
          <Button
            variant={viewMode === "split" ? "secondary" : "ghost"}
            size="sm"
            aria-pressed={viewMode === "split"}
            onclick={() => void setViewMode("split")}
          >
            <Columns2 data-icon="inline-start" aria-hidden="true" />
            Split
          </Button>
        </div>
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

  {#if documentSource}
    {#if viewMode === "source"}
      <section class="grid min-h-0 grid-rows-[auto_1fr] bg-card" aria-label={`Source of ${documentName}`}>
        {#if errorMessage}
          <p class="border-b border-border px-8 py-2 text-sm text-destructive" role="alert">
            {errorMessage}
          </p>
        {:else}
          <div></div>
        {/if}
        <Editor value={sourceText} onchange={handleEdit} />
      </section>
    {:else if viewMode === "split"}
      <section class="grid min-h-0 grid-rows-[auto_1fr] bg-card" aria-label={`Split view of ${documentName}`}>
        {#if errorMessage}
          <p class="border-b border-border px-8 py-2 text-sm text-destructive" role="alert">
            {errorMessage}
          </p>
        {:else}
          <div></div>
        {/if}
        <div class="grid min-h-0 grid-cols-2">
          <div class="min-h-0 border-r border-border">
            <Editor value={sourceText} onchange={handleEdit} />
          </div>
          <div class="min-h-0 overflow-auto">
            <article class="markdown mx-auto w-full max-w-[46rem] px-8 py-14">
              {@html renderedHtml}
            </article>
          </div>
        </div>
      </section>
    {:else}
      <section class="min-h-0 overflow-auto bg-card" aria-label={`Rendered ${documentName}`}>
        {#if errorMessage}
          <p class="border-b border-border px-8 py-2 text-sm text-destructive" role="alert">
            {errorMessage}
          </p>
        {/if}
        <article class="markdown mx-auto w-full max-w-[46rem] px-8 py-14">
          {@html renderedHtml}
        </article>
      </section>
    {/if}
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
        <div class="mt-6 flex justify-center gap-2">
          <Button size="lg" onclick={openFile} disabled={isOpening}>
            <FolderOpen data-icon="inline-start" aria-hidden="true" />
            {isOpening ? "Opening…" : "Open file"}
          </Button>
          <Button variant="outline" size="lg" onclick={pasteClipboard} disabled={isPasting}>
            <ClipboardPaste data-icon="inline-start" aria-hidden="true" />
            {isPasting ? "Pasting…" : "Paste clipboard"}
          </Button>
        </div>
        {#if errorMessage}
          <p class="mt-4 text-sm text-destructive" role="alert">{errorMessage}</p>
        {/if}
      </div>
    </section>
  {/if}
</main>

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
        {documentName} has unsaved changes. Save them before continuing?
      </p>
      <div class="mt-6 flex justify-end gap-2">
        <Button variant="ghost" size="sm" onclick={() => confirmResolve?.("cancel")}>
          Cancel
        </Button>
        <Button variant="outline" size="sm" onclick={() => confirmResolve?.("discard")}>
          Discard
        </Button>
        <Button size="sm" onclick={() => confirmResolve?.("save")}>Save</Button>
      </div>
    </div>
  </div>
{/if}
