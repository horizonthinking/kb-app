import { describe, expect, it } from "vitest";

import { guideCopyFor, setupPromptFor } from "./settings_copy";
import { MESSAGE_KEYS } from "~/i18n";

describe("AI settings copy", () => {
  it("guide and setup copy are provider-specific", () => {
    expect(guideCopyFor("gemini")).toEqual({
      connection: "settings.plugin.ai_chat.guide.gemini.connection",
      save: "settings.plugin.ai_chat.guide.gemini.save",
      openChat: "settings.plugin.ai_chat.guide.gemini.open_chat",
    });
    expect(guideCopyFor("openai")).toEqual({
      connection: "settings.plugin.ai_chat.guide.openai.connection",
      save: "settings.plugin.ai_chat.guide.openai.save",
      openChat: "settings.plugin.ai_chat.guide.openai.open_chat",
    });
    expect(guideCopyFor("remote")).toEqual({
      connection: "settings.plugin.ai_chat.guide.remote.connection",
      save: "settings.plugin.ai_chat.guide.remote.save",
      openChat: "settings.plugin.ai_chat.guide.remote.open_chat",
    });
    const promptKeys = [
      setupPromptFor("gemini"),
      setupPromptFor("openai"),
      setupPromptFor("remote"),
    ];
    expect(new Set(promptKeys).size).toBe(3);
    for (const key of [
      ...Object.values(guideCopyFor("gemini")),
      ...Object.values(guideCopyFor("openai")),
      ...Object.values(guideCopyFor("remote")),
      ...promptKeys,
    ]) {
      expect(MESSAGE_KEYS).toContain(key);
    }
  });
});
