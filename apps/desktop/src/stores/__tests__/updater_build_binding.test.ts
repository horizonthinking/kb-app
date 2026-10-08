import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

describe("H4 updater build binding", () => {
  it("moon task env binding", () => {
    const moon = readFileSync(fileURLToPath(new URL("../../../moon.yml", import.meta.url)), "utf8");
    const task = /  tauri-build-h4:\n(?<body>[\s\S]*?)(?=\n  [a-z][a-z0-9-]*:|$)/.exec(moon)?.groups
      ?.body;

    expect(task).toBeDefined();
    expect(task).toContain('VITE_KUKU_UPDATER: "off"');
  });
});
