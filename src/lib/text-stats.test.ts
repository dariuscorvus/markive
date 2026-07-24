import { describe, expect, test } from "vitest";

import { countWords } from "./text-stats";

describe("countWords", () => {
  test("an empty string has no words", () => {
    expect(countWords("")).toBe(0);
  });

  test("whitespace-only text has no words", () => {
    expect(countWords("   \n\t  ")).toBe(0);
  });

  test("a single word counts as one", () => {
    expect(countWords("hello")).toBe(1);
  });

  test("words separated by mixed whitespace all count", () => {
    expect(countWords("one two\tthree\nfour   five")).toBe(5);
  });

  test("leading and trailing whitespace is ignored", () => {
    expect(countWords("  hello world  ")).toBe(2);
  });
});
