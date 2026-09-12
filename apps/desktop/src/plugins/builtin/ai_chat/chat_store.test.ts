import { beforeEach, describe, expect, it, vi } from "vitest";

const mockInvoke = vi.fn();
const mockReadVaultFileWithChecksum = vi.fn();
const mockContextSnapshot = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: mockInvoke,
}));

vi.mock("~/lib/vault_fs", () => ({
  readVaultFileWithChecksum: mockReadVaultFileWithChecksum,
}));

vi.mock("./approval_diff", () => ({
  openApprovalDiff: vi.fn(),
}));

vi.mock("./context_snapshot", () => ({
  createContextSnapshotSource: () => ({
    snapshot: mockContextSnapshot,
  }),
}));

vi.mock("./responding_state", () => ({
  hasRespondingSession: () => false,
}));

vi.mock("~/plugins/context_keys", () => ({
  setContextKey: vi.fn(),
}));

async function loadChatStoreModule() {
  vi.resetModules();
  return import("./chat_store");
}

function defaultEditorContext() {
  return {
    activeFile: null,
    selectedText: null,
    openTabs: [],
    cursorLine: null,
  };
}

describe("ai_chat chat_store config", () => {
  beforeEach(() => {
    mockInvoke.mockReset();
    mockReadVaultFileWithChecksum.mockReset();
    mockContextSnapshot.mockReset();
    mockContextSnapshot.mockImplementation(defaultEditorContext);
  });

  it("loads openai settings without pinning the model to the build default", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin_get_settings_with_secrets":
          return {
            provider: "openai",
            apiKey: null,
            openaiApiKey: null,
            openaiBaseUrl: "http://127.0.0.1:11434/v1",
            openaiModel: "qwen3.5:4b",
            model: "stale-build-default",
            serverUrl: "http://localhost:8080",
            roundLimit: 16,
            proxyToolTimeoutMs: 30_000,
          };
        case "plugin_save_settings_with_secrets":
        case "plugin:kuku-ai|ai_set_config":
          return undefined;
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });

    const chat = await loadChatStoreModule();

    await chat.loadConfig();

    expect(mockInvoke).toHaveBeenCalledWith("plugin_get_settings_with_secrets", {
      pluginId: "ai-chat",
      secureKeys: ["apiKey", "openaiApiKey"],
    });
    expect(mockInvoke).toHaveBeenNthCalledWith(2, "plugin:kuku-ai|ai_set_config", {
      config: expect.objectContaining({
        provider: "openai",
        apiKey: null,
        openaiBaseUrl: "http://127.0.0.1:11434/v1",
        openaiModel: "qwen3.5:4b",
        model: "qwen3.5:4b",
      }),
    });
    expect(chat.chatState.config.provider).toBe("openai");
    expect(chat.chatState.config.model).toBe("qwen3.5:4b");
  });

  it("saveSettingsDraft persists both secure keys and syncs runtime config", async () => {
    mockInvoke.mockResolvedValue(undefined);

    const chat = await loadChatStoreModule();
    chat.setSettingsDraft({
      provider: "openai",
      apiKey: "   ",
      openaiApiKey: "  sk-test  ",
      openaiModel: "gpt-5-nano",
    });
    await chat.saveSettingsDraft();

    expect(mockInvoke).toHaveBeenNthCalledWith(2, "plugin_save_settings_with_secrets", {
      pluginId: "ai-chat",
      settings: expect.objectContaining({
        provider: "openai",
        apiKey: null,
        openaiApiKey: "sk-test",
        openaiModel: "gpt-5-nano",
        model: "gpt-5-nano",
      }),
      secureKeys: ["apiKey", "openaiApiKey"],
    });
    expect(mockInvoke).toHaveBeenNthCalledWith(1, "plugin:kuku-ai|ai_set_config", {
      config: expect.objectContaining({
        provider: "openai",
        apiKey: null,
        openaiApiKey: "sk-test",
        model: "gpt-5-nano",
      }),
    });
  });

  it("saveSettingsDraft rolls back persisted settings when ai_set_config rejects", async () => {
    const persistedBefore = {
      provider: "remote",
      apiKey: null,
      openaiApiKey: null,
      openaiBaseUrl: "http://127.0.0.1:11434/v1",
      openaiModel: null,
      model: "default",
      serverUrl: "https://api.kuku.mom",
      roundLimit: 16,
      proxyToolTimeoutMs: 30_000,
    };
    const persistedWrites: unknown[] = [];
    mockInvoke.mockImplementation(async (command: string, payload: Record<string, unknown>) => {
      if (command === "plugin_get_settings_with_secrets") return persistedBefore;
      if (command === "plugin:kuku-ai|ai_set_config") {
        const config = payload.config as { provider?: string };
        if (config.provider === "openai") throw new Error("invalid endpoint");
        return undefined;
      }
      if (command === "plugin_save_settings_with_secrets") {
        persistedWrites.push(payload.settings);
        return undefined;
      }
      throw new Error(`unexpected invoke: ${command}`);
    });

    const chat = await loadChatStoreModule();
    await chat.loadConfig();
    persistedWrites.length = 0;
    chat.setSettingsDraft({
      provider: "openai",
      openaiBaseUrl: "http://public.example/v1",
      openaiModel: "bad-model",
    });
    await chat.saveSettingsDraft();

    expect(persistedWrites).toEqual([]);
    expect(chat.chatState.config.rawConfig).toMatchObject({ provider: "remote" });
    expect(chat.chatState.config.error).toBe("invalid endpoint");

    mockInvoke.mockReset();
    mockInvoke
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error("disk full"))
      .mockResolvedValueOnce(undefined);
    chat.setSettingsDraft({ provider: "gemini", apiKey: "key-G" });
    await chat.saveSettingsDraft();

    expect(mockInvoke).toHaveBeenNthCalledWith(1, "plugin:kuku-ai|ai_set_config", {
      config: expect.objectContaining({ provider: "gemini", apiKey: "key-G" }),
    });
    expect(mockInvoke).toHaveBeenNthCalledWith(2, "plugin_save_settings_with_secrets", {
      pluginId: "ai-chat",
      settings: expect.objectContaining({ provider: "gemini", apiKey: "key-G" }),
      secureKeys: ["apiKey", "openaiApiKey"],
    });
    expect(mockInvoke).toHaveBeenNthCalledWith(3, "plugin:kuku-ai|ai_set_config", {
      config: expect.objectContaining({ provider: "remote" }),
    });
    expect(chat.chatState.config.rawConfig).toMatchObject({ provider: "remote" });
    expect(chat.chatState.config.error).toBe("disk full");
  });

  it("loadConfig does not re-persist an invalid configuration and recovers", async () => {
    const persistedWrites: unknown[] = [];
    let rejectInvalid = true;
    mockInvoke.mockImplementation(async (command: string, payload: Record<string, unknown>) => {
      if (command === "plugin_get_settings_with_secrets") {
        return {
          provider: "openai",
          openaiBaseUrl: "http://public.example/v1",
          openaiModel: "bad-model",
        };
      }
      if (command === "plugin:kuku-ai|ai_set_config") {
        const config = payload.config as { provider?: string };
        if (rejectInvalid && config.provider === "openai") throw new Error("invalid endpoint");
        return undefined;
      }
      if (command === "plugin_save_settings_with_secrets") {
        persistedWrites.push(payload.settings);
        return undefined;
      }
      throw new Error(`unexpected invoke: ${command}`);
    });

    const chat = await loadChatStoreModule();
    await chat.loadConfig();

    expect(persistedWrites).toEqual([]);
    expect(chat.chatState.config.provider).toBe("remote");
    expect(chat.chatState.config.error).toBe("invalid endpoint");

    rejectInvalid = false;
    chat.setSettingsDraft({
      provider: "openai",
      openaiBaseUrl: "http://127.0.0.1:11434/v1",
      openaiModel: "qwen3.5:4b",
    });
    await chat.saveSettingsDraft();

    expect(persistedWrites).toHaveLength(1);
    expect(persistedWrites[0]).toMatchObject({
      provider: "openai",
      openaiBaseUrl: "http://127.0.0.1:11434/v1",
      openaiModel: "qwen3.5:4b",
    });
    expect(chat.chatState.config.provider).toBe("openai");
    expect(chat.chatState.config.error).toBeNull();
  });

  it("clearPersistedConfig clears both secure keys", async () => {
    mockInvoke.mockResolvedValue(undefined);

    const chat = await loadChatStoreModule();

    await chat.clearPersistedConfig();

    expect(mockInvoke).toHaveBeenCalledWith("plugin_clear_settings_with_secrets", {
      pluginId: "ai-chat",
      secureKeys: ["apiKey", "openaiApiKey"],
    });
  });

  it("loadModelSuggestions lists models for the current draft", async () => {
    mockInvoke.mockResolvedValueOnce(["gpt-5-nano", "qwen3.5:4b"]);
    const chat = await loadChatStoreModule();
    chat.setSettingsDraft({
      openaiBaseUrl: "https://models.example/v1",
      openaiApiKey: "  sk-test  ",
    });

    await chat.loadModelSuggestions();

    expect(mockInvoke).toHaveBeenLastCalledWith("plugin:kuku-ai|ai_list_models", {
      baseUrl: "https://models.example/v1",
      apiKey: "sk-test",
    });
    expect(chat.chatState.config.modelSuggestions).toEqual(["gpt-5-nano", "qwen3.5:4b"]);

    mockInvoke.mockResolvedValueOnce(["local-model"]);
    chat.setSettingsDraft({ openaiApiKey: "   " });
    await chat.loadModelSuggestions();
    expect(mockInvoke).toHaveBeenLastCalledWith("plugin:kuku-ai|ai_list_models", {
      baseUrl: "https://models.example/v1",
      apiKey: null,
    });

    mockInvoke.mockRejectedValueOnce(new Error("model discovery failed"));
    await chat.loadModelSuggestions();
    expect(chat.chatState.config.modelSuggestions).toEqual([]);
    expect(chat.chatState.config.modelsError).toBe("model discovery failed");
  });

  it("provider round trip keeps every provider's fields", async () => {
    mockInvoke.mockResolvedValue(undefined);
    const chat = await loadChatStoreModule();
    chat.setSettingsDraft({
      provider: "openai",
      apiKey: "",
      openaiApiKey: "key-A",
      openaiBaseUrl: "https://compatible.example/v1",
      openaiModel: "model-M1",
    });
    await chat.saveSettingsDraft();
    chat.setSettingsDraft({ provider: "gemini", apiKey: "key-G" });
    await chat.saveSettingsDraft();
    await chat.switchProviderAndSave("openai");

    const saved = mockInvoke.mock.calls
      .filter(([command]) => command === "plugin_save_settings_with_secrets")
      .map(([, payload]) => payload.settings);
    expect(saved).toHaveLength(3);
    expect(saved[0]).toMatchObject({
      provider: "openai",
      apiKey: null,
      openaiApiKey: "key-A",
      openaiBaseUrl: "https://compatible.example/v1",
      openaiModel: "model-M1",
    });
    expect(saved[1]).toMatchObject({
      provider: "gemini",
      apiKey: "key-G",
      openaiApiKey: "key-A",
      openaiBaseUrl: "https://compatible.example/v1",
      openaiModel: "model-M1",
    });
    expect(saved[2]).toMatchObject({
      provider: "openai",
      apiKey: "key-G",
      openaiApiKey: "key-A",
      openaiBaseUrl: "https://compatible.example/v1",
      openaiModel: "model-M1",
    });
  });

  it("switchProviderAndSave keeps openai fields when moving to remote", async () => {
    mockInvoke.mockResolvedValue(undefined);
    const chat = await loadChatStoreModule();
    chat.setSettingsDraft({
      provider: "openai",
      openaiApiKey: "key-A",
      openaiBaseUrl: "https://compatible.example/v1",
      openaiModel: "model-M1",
    });
    await chat.saveSettingsDraft();
    await chat.switchProviderAndSave("remote");

    expect(mockInvoke).toHaveBeenCalledWith("plugin:kuku-ai|ai_set_config", {
      config: expect.objectContaining({
        provider: "remote",
        openaiApiKey: "key-A",
        openaiBaseUrl: "https://compatible.example/v1",
        openaiModel: "model-M1",
      }),
    });
  });

  it("first-run discovery works before a model is chosen", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      if (command === "plugin:kuku-ai|ai_list_models") return ["qwen3.5:4b"];
      return undefined;
    });
    const chat = await loadChatStoreModule();
    chat.setSettingsDraft({
      provider: "openai",
      openaiApiKey: "",
      openaiBaseUrl: "http://127.0.0.1:11434/v1",
      openaiModel: "",
    });

    await chat.saveSettingsDraft();
    await chat.loadModelSuggestions();
    expect(chat.chatState.config.modelSuggestions).toEqual(["qwen3.5:4b"]);
    expect(mockInvoke).toHaveBeenCalledWith("plugin:kuku-ai|ai_list_models", {
      baseUrl: "http://127.0.0.1:11434/v1",
      apiKey: null,
    });
    chat.setSettingsDraft({ openaiModel: chat.chatState.config.modelSuggestions[0] });
    await chat.saveSettingsDraft();
    expect(mockInvoke).toHaveBeenCalledWith("plugin:kuku-ai|ai_set_config", {
      config: expect.objectContaining({ model: "qwen3.5:4b" }),
    });
  });
});

describe("ai_chat chat_store session modes", () => {
  beforeEach(() => {
    mockInvoke.mockReset();
    mockReadVaultFileWithChecksum.mockReset();
    mockContextSnapshot.mockReset();
    mockContextSnapshot.mockImplementation(defaultEditorContext);
  });

  it("composer setDraft still stores the session draft string", async () => {
    mockInvoke.mockResolvedValue({ sessionId: "session-1" });
    const chat = await loadChatStoreModule();

    await chat.createSession("ask");
    chat.setDraft("hello");

    expect(chat.chatState.sessions["session-1"]?.draft).toBe("hello");
  });

  it("switches mode without creating a new session", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin:kuku-ai|ai_new_session":
          return { sessionId: "session-1" };
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });

    const chat = await loadChatStoreModule();

    await chat.createSession("ask");
    chat.setDraft("keep this draft");
    await chat.switchMode("agent");

    expect(chat.chatState.activeSessionId).toBe("session-1");
    expect(chat.chatState.selectedMode).toBe("agent");
    expect(chat.chatState.sessions["session-1"]?.mode).toBe("agent");
    expect(chat.chatState.sessions["session-1"]?.draft).toBe("keep this draft");
    expect(mockInvoke).toHaveBeenCalledTimes(1);
    expect(mockInvoke).toHaveBeenCalledWith("plugin:kuku-ai|ai_new_session", {
      mode: "ask",
    });
  });

  it("can switch back to ask mode without creating a new session", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin:kuku-ai|ai_new_session":
          return { sessionId: "session-1" };
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });

    const chat = await loadChatStoreModule();

    await chat.createSession("ask");
    await chat.switchMode("agent");
    await chat.switchMode("ask");

    expect(chat.chatState.activeSessionId).toBe("session-1");
    expect(chat.chatState.selectedMode).toBe("ask");
    expect(chat.chatState.sessions["session-1"]?.mode).toBe("ask");
    expect(mockInvoke).toHaveBeenCalledTimes(1);
  });

  it("keeps the current session when sending after a mode switch", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin:kuku-ai|ai_new_session":
          return { sessionId: "session-1" };
        case "plugin:kuku-ai|ai_send_message":
          return undefined;
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });

    const chat = await loadChatStoreModule();

    await chat.createSession("ask");
    await chat.switchMode("agent");
    await chat.sendMessage("edit this note");

    expect(chat.chatState.activeSessionId).toBe("session-1");
    expect(chat.chatState.sessions["session-1"]?.messages).toMatchObject([
      {
        kind: "text",
        role: "user",
        content: "edit this note",
      },
    ]);
    expect(mockInvoke).toHaveBeenCalledTimes(2);
    expect(mockInvoke).toHaveBeenNthCalledWith(2, "plugin:kuku-ai|ai_send_message", {
      sessionId: "session-1",
      mode: "agent",
      content: "edit this note",
      editorContext: {
        activeFile: null,
        selectedText: null,
        openTabs: [],
        cursorLine: null,
        embeddedFiles: [],
      },
    });
  });

  it("sends attached files as embedded editor context", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin:kuku-ai|ai_new_session":
          return { sessionId: "session-1" };
        case "plugin:kuku-ai|ai_send_message":
          return undefined;
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });
    mockReadVaultFileWithChecksum.mockResolvedValue({
      content: "# Base\ncontent",
      checksum: "checksum-1",
    });

    const chat = await loadChatStoreModule();

    await chat.createSession("agent");
    await chat.addFileAttachment({
      name: "Base",
      path: "notes/Base.md",
      folder: "notes",
    });
    await chat.sendMessage("summarize this");

    expect(mockReadVaultFileWithChecksum).toHaveBeenCalledWith("notes/Base.md");
    expect(chat.chatState.sessions["session-1"]?.fileAttachments).toEqual([]);
    expect(chat.chatState.sessions["session-1"]?.messages).toMatchObject([
      {
        kind: "text",
        role: "user",
        content: "summarize this",
        attachments: [
          {
            kind: "file",
            path: "notes/Base.md",
            name: "Base",
            sizeBytes: 14,
          },
        ],
      },
    ]);
    expect(mockInvoke).toHaveBeenNthCalledWith(2, "plugin:kuku-ai|ai_send_message", {
      sessionId: "session-1",
      mode: "agent",
      content: "summarize this",
      editorContext: {
        activeFile: null,
        selectedText: null,
        openTabs: [],
        cursorLine: null,
        embeddedFiles: [
          {
            path: "notes/Base.md",
            content: "# Base\ncontent",
            checksum: "checksum-1",
            sizeBytes: 14,
          },
        ],
      },
    });
  });

  it("sends selected text as visible turn context by default", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin:kuku-ai|ai_new_session":
          return { sessionId: "session-1" };
        case "plugin:kuku-ai|ai_send_message":
          return undefined;
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });
    mockContextSnapshot.mockImplementation(() => ({
      activeFile: "notes/Base.md",
      selectedText: "selected paragraph",
      openTabs: [],
      cursorLine: null,
    }));

    const chat = await loadChatStoreModule();

    await chat.createSession("ask");
    await chat.sendMessage("explain this");

    expect(chat.chatState.sessions["session-1"]?.messages).toMatchObject([
      {
        kind: "text",
        role: "user",
        content: "explain this",
        attachments: [
          {
            kind: "selection",
            activeFile: "notes/Base.md",
            sizeBytes: 18,
          },
        ],
      },
    ]);
    expect(mockInvoke).toHaveBeenNthCalledWith(2, "plugin:kuku-ai|ai_send_message", {
      sessionId: "session-1",
      mode: "ask",
      content: "explain this",
      editorContext: {
        activeFile: "notes/Base.md",
        selectedText: "selected paragraph",
        openTabs: [],
        cursorLine: null,
        embeddedFiles: [],
      },
    });
  });

  it("can disable selected text context for precomposed prompts", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin:kuku-ai|ai_new_session":
          return { sessionId: "session-1" };
        case "plugin:kuku-ai|ai_send_message":
          return undefined;
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });
    mockContextSnapshot.mockImplementation(() => ({
      activeFile: "notes/Base.md",
      selectedText: "selected paragraph",
      openTabs: [],
      cursorLine: null,
    }));

    const chat = await loadChatStoreModule();

    await chat.createSession("ask");
    await chat.sendMessage("prompt already contains selection", { includeSelectedText: false });

    expect(chat.chatState.sessions["session-1"]?.messages).toMatchObject([
      {
        kind: "text",
        role: "user",
        content: "prompt already contains selection",
      },
    ]);
    expect(chat.chatState.sessions["session-1"]?.messages[0]).not.toHaveProperty("attachments");
    expect(mockInvoke).toHaveBeenNthCalledWith(2, "plugin:kuku-ai|ai_send_message", {
      sessionId: "session-1",
      mode: "ask",
      content: "prompt already contains selection",
      editorContext: {
        activeFile: "notes/Base.md",
        selectedText: null,
        openTabs: [],
        cursorLine: null,
        embeddedFiles: [],
      },
    });
  });

  it("lets the next selected mode change while the active session is busy", async () => {
    mockInvoke.mockImplementation(async (command: string) => {
      switch (command) {
        case "plugin:kuku-ai|ai_new_session":
          return { sessionId: "session-1" };
        default:
          throw new Error(`unexpected invoke: ${command}`);
      }
    });

    const chat = await loadChatStoreModule();

    await chat.createSession("ask");
    chat.setSessionStatus("session-1", "streaming");
    await chat.switchMode("agent");

    expect(chat.chatState.selectedMode).toBe("agent");
    expect(chat.chatState.sessions["session-1"]?.mode).toBe("agent");
    expect(mockInvoke).toHaveBeenCalledTimes(1);
  });
});
