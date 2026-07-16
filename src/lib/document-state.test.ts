import { describe, expect, test } from "vitest";

import { fileName, isDocumentDirty, isMarkdownPath, remapDocumentSource } from "./document-state";

describe("isDocumentDirty", () => {
  test("no document is never dirty", () => {
    expect(isDocumentDirty(null, "", null)).toBe(false);
    expect(isDocumentDirty(null, "leftover text", null)).toBe(false);
  });

  test("a file document is clean while the buffer matches the saved text", () => {
    const source = { kind: "file", path: "/docs/a.md" } as const;
    expect(isDocumentDirty(source, "# A\n", "# A\n")).toBe(false);
    expect(isDocumentDirty(source, "# A edited\n", "# A\n")).toBe(true);
  });

  test("editing back to the saved text makes the document clean again", () => {
    const source = { kind: "file", path: "/docs/a.md" } as const;
    expect(isDocumentDirty(source, "# A\n", "# A\n")).toBe(false);
  });

  test("saving transitions dirty to clean by updating savedText", () => {
    const source = { kind: "file", path: "/docs/a.md" } as const;
    const edited = "# A edited\n";
    expect(isDocumentDirty(source, edited, "# A\n")).toBe(true);
    expect(isDocumentDirty(source, edited, edited)).toBe(false);
  });

  test("pathless documents are dirty once they hold text", () => {
    for (const kind of ["clipboard", "stdin", "untitled"] as const) {
      expect(isDocumentDirty({ kind }, "", null)).toBe(false);
      expect(isDocumentDirty({ kind }, "pasted", null)).toBe(true);
    }
  });

  test("a file whose disk copy disappeared is dirty while it holds text", () => {
    // handleFileChange sets savedText to null when the file is
    // removed: the buffer is the only copy.
    const source = { kind: "file", path: "/docs/gone.md" } as const;
    expect(isDocumentDirty(source, "# Content\n", null)).toBe(true);
    expect(isDocumentDirty(source, "", null)).toBe(false);
  });
});

describe("isMarkdownPath", () => {
  test("accepts every registered extension, case-insensitively", () => {
    for (const path of ["a.md", "b.markdown", "c.mdown", "d.mkd", "e.MD", "/x/y/F.Markdown"]) {
      expect(isMarkdownPath(path)).toBe(true);
    }
  });

  test("rejects other files and extension-less paths", () => {
    for (const path of ["a.txt", "b.md.png", "README", "archive.tar.gz", "md"]) {
      expect(isMarkdownPath(path)).toBe(false);
    }
  });
});

describe("remapDocumentSource", () => {
  test("remaps a file source that was itself renamed or moved", () => {
    const source = { kind: "file", path: "/docs/old.md" } as const;
    expect(remapDocumentSource(source, "/docs/old.md", "/docs/new.md")).toEqual({
      kind: "file",
      path: "/docs/new.md",
    });
  });

  test("remaps a file nested under a renamed or moved folder", () => {
    const source = { kind: "file", path: "/docs/notes/deep/a.md" } as const;
    expect(remapDocumentSource(source, "/docs/notes", "/docs/renamed")).toEqual({
      kind: "file",
      path: "/docs/renamed/deep/a.md",
    });
  });

  test("leaves an unrelated file source untouched", () => {
    const source = { kind: "file", path: "/docs/other.md" } as const;
    expect(remapDocumentSource(source, "/docs/old.md", "/docs/new.md")).toEqual(source);
  });

  test("does not match a sibling whose name is a prefix of the renamed path", () => {
    // "/docs/notes-extra/a.md" must not be treated as nested under
    // "/docs/notes" just because the string starts with it.
    const source = { kind: "file", path: "/docs/notes-extra/a.md" } as const;
    expect(remapDocumentSource(source, "/docs/notes", "/docs/renamed")).toEqual(source);
  });

  test("leaves pathless sources untouched", () => {
    for (const kind of ["clipboard", "stdin", "untitled"] as const) {
      const source = { kind };
      expect(remapDocumentSource(source, "/docs/old.md", "/docs/new.md")).toEqual(source);
    }
  });
});

describe("fileName", () => {
  test("returns the last path component for both separators", () => {
    expect(fileName("/docs/notes/a.md")).toBe("a.md");
    expect(fileName("C:\\docs\\a.md")).toBe("a.md");
    expect(fileName("a.md")).toBe("a.md");
  });
});
