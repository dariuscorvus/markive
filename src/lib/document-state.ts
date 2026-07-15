// Pure document-state logic, kept out of App.svelte so the dirty
// rules and path checks are unit-testable.

export type DocumentSource =
  | { kind: "file"; path: string }
  | { kind: "clipboard" }
  | { kind: "stdin" }
  | { kind: "untitled" };

export const MARKDOWN_EXTENSIONS = ["md", "markdown", "mdown", "mkd"];

export function fileName(path: string): string {
  return path.split(/[\\/]/).pop() ?? path;
}

export function isMarkdownPath(path: string): boolean {
  // A name without a dot has no extension — "md" is not a Markdown
  // file, matching the backend's Path::extension semantics.
  const name = fileName(path);
  if (!name.includes(".")) return false;

  const extension = name.split(".").pop()?.toLowerCase() ?? "";
  return MARKDOWN_EXTENSIONS.includes(extension);
}

// Documents without a saved form (clipboard, stdin, untitled) are
// dirty once they hold text; an empty untitled document is clean so
// an unused window closes without a prompt. `savedText` is the
// content as last loaded or saved, null for documents that never had
// a file.
export function isDocumentDirty(
  source: DocumentSource | null,
  sourceText: string,
  savedText: string | null,
): boolean {
  if (source === null) return false;
  return savedText === null ? sourceText.length > 0 : sourceText !== savedText;
}
