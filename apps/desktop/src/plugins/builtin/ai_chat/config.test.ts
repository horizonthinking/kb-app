import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import {
  DEFAULT_MODEL,
  DEFAULT_OPENAI_BASE_URL,
  DEFAULT_PROVIDER,
  endpointPolicyFor,
  normalizeAiConfig,
  normalizeApiKey,
} from "./config";

describe("AI chat configuration", () => {
  it("normalizes openai provider with defaults", () => {
    const config = normalizeAiConfig({ provider: "openai", openaiModel: "gpt-5-nano" });

    expect(config.openaiBaseUrl).toBe(DEFAULT_OPENAI_BASE_URL);
    expect(config.openaiApiKey).toBeNull();
    expect(config.model).toBe("gpt-5-nano");
  });

  it("derives top-level model per provider", () => {
    expect(
      normalizeAiConfig({ provider: "openai", model: "ignored", openaiModel: "qwen3.5:4b" }).model,
    ).toBe("qwen3.5:4b");
    expect(
      normalizeAiConfig({ provider: "gemini", model: "ignored", openaiModel: "also-ignored" })
        .model,
    ).toBe(DEFAULT_MODEL);
    expect(
      normalizeAiConfig({ provider: "remote", model: "ignored", openaiModel: "also-ignored" })
        .model,
    ).toBe(DEFAULT_MODEL);
  });

  it("keeps legacy configs without openai fields loadable", () => {
    const config = normalizeAiConfig({
      provider: "gemini",
      apiKey: "k",
      model: "gemini-3.1-flash-lite",
    });

    expect(config.provider).toBe("gemini");
    expect(config.apiKey).toBe("k");
    expect(config.openaiApiKey).toBeNull();
    expect(config.openaiBaseUrl).toBe(DEFAULT_OPENAI_BASE_URL);
    expect(config.openaiModel).toBeNull();
  });

  it("rejects unknown provider values to the default", () => {
    expect(normalizeAiConfig({ provider: "codexAppServer" }).provider).toBe(DEFAULT_PROVIDER);
  });

  it("normalizes api keys the same way as Rust", () => {
    expect(normalizeApiKey(null)).toBeNull();
    expect(normalizeApiKey("")).toBeNull();
    expect(normalizeApiKey("   ")).toBeNull();
    expect(normalizeApiKey("  sk-test  ")).toBe("sk-test");
    expect(normalizeAiConfig({ apiKey: "  gemini  ", openaiApiKey: "  openai  " })).toMatchObject({
      apiKey: "gemini",
      openaiApiKey: "openai",
    });
  });

  it("endpointPolicyFor matches the shared fixtures", () => {
    const fixturePath = fileURLToPath(
      new URL("../../../../../../crates/kuku-ai/fixtures/host_policy.json", import.meta.url),
    );
    const fixtures = JSON.parse(readFileSync(fixturePath, "utf8")) as {
      url: string;
      key_present: boolean;
      requirement: "required" | "optional";
      accepted: boolean;
    }[];

    expect(fixtures).toHaveLength(25);
    for (const fixture of fixtures) {
      expect(endpointPolicyFor(fixture.url, fixture.key_present), fixture.url).toEqual({
        requirement: fixture.requirement,
        accepted: fixture.accepted,
      });
    }
  });
});
