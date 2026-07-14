<script lang="ts">
  import { ClipboardPaste, Code, Eye, FileText, FolderOpen } from "@lucide/svelte";
  import { convertFileSrc, invoke } from "@tauri-apps/api/core";
  import { listen } from "@tauri-apps/api/event";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import { onMount } from "svelte";
  import { readText } from "@tauri-apps/plugin-clipboard-manager";
  import { open } from "@tauri-apps/plugin-dialog";
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
  let viewMode = $state<"rendered" | "source">("rendered");
  let errorMessage = $state<string | null>(null);
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
    viewMode = "rendered";
  }

  function handleEdit(value: string) {
    sourceText = value;
  }

  async function toggleViewMode() {
    if (viewMode === "rendered") {
      viewMode = "source";
      return;
    }

    // Back to rendered: re-render the possibly edited source.
    try {
      const html = await invoke<string>("render_source", {
        markdown: sourceText,
        baseDir,
      });
      renderedHtml = convertLocalImageSources(html);
      viewMode = "rendered";
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    }
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

      await openDocumentAtPath(selectedPath);
    } catch (error) {
      errorMessage = error instanceof Error ? error.message : String(error);
    } finally {
      isOpening = false;
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
      } else if (request.path) {
        await openDocumentAtPath(request.path);
      } else if (request.stdinPath) {
        const stdinDocument = await invoke<StdinDocument>("open_stdin_document", {
          path: request.stdinPath,
        });
        documentSource = { kind: "stdin" };
        renderedHtml = convertLocalImageSources(stdinDocument.html);
        sourceText = stdinDocument.content;
        viewMode = "rendered";
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

    if (key === "e" && documentSource) {
      event.preventDefault();
      void toggleViewMode();
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
  <title>{documentName}</title>
</svelte:head>

<svelte:window onkeydown={handleKeydown} />

<main
  class={`grid min-h-screen grid-rows-[2.75rem_1fr] bg-background text-foreground ${isDragOver ? "ring-2 ring-inset ring-ring" : ""}`}
>
  <header class="path-rail flex items-center justify-between gap-4 border-b border-border px-4">
    <div class="flex min-w-0 items-center gap-2 font-mono text-xs text-muted-foreground">
      <FileText aria-hidden="true" class="size-3.5 shrink-0" strokeWidth={1.75} />
      <span class="truncate">{sourceLabel}</span>
    </div>
    {#if documentSource}
      <div class="flex items-center gap-1">
        <Button variant="ghost" size="sm" onclick={toggleViewMode}>
          {#if viewMode === "rendered"}
            <Code data-icon="inline-start" aria-hidden="true" />
            Source
          {:else}
            <Eye data-icon="inline-start" aria-hidden="true" />
            Rendered
          {/if}
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
