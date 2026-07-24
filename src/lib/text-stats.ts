// Pure text-statistics logic for the status bar, kept out of
// Editor.svelte so word counting is unit-testable.

export function countWords(text: string): number {
  const trimmed = text.trim();
  return trimmed === "" ? 0 : trimmed.split(/\s+/).length;
}
