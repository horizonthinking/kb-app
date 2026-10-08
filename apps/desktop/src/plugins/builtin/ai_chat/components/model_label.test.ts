import { describe, expect, it } from "vitest";

import { shortModelLabel } from "./model_label";

describe("model labels", () => {
  it("shortModelLabel keeps gemini labels and passes other ids through", () => {
    expect(shortModelLabel("gemini-3.1-flash-lite")).toBe("Gemini 3.1 Flash Lite");
    expect(shortModelLabel("gpt-5-nano")).toBe("gpt-5-nano");
    expect(shortModelLabel("qwen3.5:4b")).toBe("qwen3.5:4b");
    expect(shortModelLabel("")).toBe("—");
  });
});
