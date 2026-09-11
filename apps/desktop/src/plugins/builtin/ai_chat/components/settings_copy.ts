import { assertNever } from "../config";
import type { AiProvider } from "../types";
import type { MessageKey } from "~/i18n";

interface GuideCopy {
  connection: MessageKey;
  save: MessageKey;
  openChat: MessageKey;
}

function guideCopyFor(provider: AiProvider): GuideCopy {
  switch (provider) {
    case "gemini":
      return {
        connection: "settings.plugin.ai_chat.guide.gemini.connection",
        save: "settings.plugin.ai_chat.guide.gemini.save",
        openChat: "settings.plugin.ai_chat.guide.gemini.open_chat",
      };
    case "openai":
      return {
        connection: "settings.plugin.ai_chat.guide.openai.connection",
        save: "settings.plugin.ai_chat.guide.openai.save",
        openChat: "settings.plugin.ai_chat.guide.openai.open_chat",
      };
    case "remote":
      return {
        connection: "settings.plugin.ai_chat.guide.remote.connection",
        save: "settings.plugin.ai_chat.guide.remote.save",
        openChat: "settings.plugin.ai_chat.guide.remote.open_chat",
      };
    default:
      return assertNever(provider);
  }
}

function setupPromptFor(provider: AiProvider): MessageKey {
  switch (provider) {
    case "gemini":
      return "chat.panel.setup.prompt_gemini";
    case "openai":
      return "chat.panel.setup.prompt_openai";
    case "remote":
      return "chat.panel.setup.prompt_remote";
    default:
      return assertNever(provider);
  }
}

export { guideCopyFor, setupPromptFor };
export type { GuideCopy };
