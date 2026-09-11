import { For, Show, createEffect, createMemo, createSignal, on, type JSX } from "solid-js";

import {
  chatState,
  isSettingsDraftUnsaved,
  loadConfig,
  loadModelSuggestions,
  loadTools,
  saveSettingsDraft,
  setSettingsDraft,
} from "../chat_store";
import { AI_PROVIDERS, assertNever, keyRequirementFor, normalizeApiKey } from "../config";
import { formatToolIdentity, getToolInfo } from "../tool_identity";
import type { AiProvider } from "../types";
import { shortModelLabel } from "./model_label";
import { guideCopyFor } from "./settings_copy";
import { ChevronIcon, EyeIcon, EyeOffIcon } from "~/components/icons";
import ScrollArea from "~/components/scroll_area";
import {
  SettingsBanner,
  SettingsCard,
  SettingsFieldRow,
  SettingsInput,
  SettingsListRow,
  SettingsPanel,
  SettingsSelect,
  SettingsToolbarAction,
} from "~/components/settings/settings_blocks";
import { useSettingsRefreshToken } from "~/components/settings/settings_refresh";
import { t, tf } from "~/i18n";
import { openSettings } from "~/stores/files";

function openAccountSettings(): void {
  openSettings({ kind: "plugin", fillId: "core-auth.settings", anchor: "session" });
}

function providerOptionLabel(provider: AiProvider): string {
  switch (provider) {
    case "remote":
      return t("settings.plugin.ai_chat.connection.option_remote");
    case "gemini":
      return t("settings.plugin.ai_chat.connection.option_gemini");
    case "openai":
      return t("settings.plugin.ai_chat.connection.option_openai");
    default:
      return assertNever(provider);
  }
}

function ApiKeyInput(props: {
  value: string;
  visible: boolean;
  setVisible: (visible: boolean) => void;
  onInput: (value: string) => void;
}): JSX.Element {
  return (
    <div class="relative w-full">
      <SettingsInput
        type={props.visible ? "text" : "password"}
        value={props.value}
        placeholder={t("settings.plugin.ai_chat.api_key.placeholder")}
        class="pr-9"
        autocomplete="off"
        spellcheck={false}
        onInput={(event) => props.onInput(event.currentTarget.value)}
      />
      <button
        type="button"
        class="absolute inset-y-0 right-0 flex items-center px-2.5 text-text-muted transition-colors hover:text-text-primary"
        onClick={() => props.setVisible(!props.visible)}
        tabIndex={-1}
        title={
          props.visible
            ? t("settings.plugin.ai_chat.api_key.hide")
            : t("settings.plugin.ai_chat.api_key.show")
        }
      >
        <Show when={props.visible} fallback={<EyeIcon size={14} />}>
          <EyeOffIcon size={14} />
        </Show>
      </button>
    </div>
  );
}

function AiSettings(): JSX.Element {
  const [showGeminiApiKey, setShowGeminiApiKey] = createSignal(false);
  const [showOpenAiApiKey, setShowOpenAiApiKey] = createSignal(false);
  const settingsRefreshToken = useSettingsRefreshToken();

  createEffect(
    on(settingsRefreshToken, () => void Promise.all([loadConfig(), loadTools()]), { defer: false }),
  );

  const isUnsaved = createMemo(isSettingsDraftUnsaved);
  const guideCopy = createMemo(() => guideCopyFor(chatState.config.settingsDraft.provider));
  const openAiKeyRequirement = createMemo(() =>
    keyRequirementFor(chatState.config.settingsDraft.openaiBaseUrl),
  );
  const providerOptions = createMemo(() =>
    AI_PROVIDERS.map((provider) => ({ value: provider, label: providerOptionLabel(provider) })),
  );
  const saveButtonLabel = createMemo(() => {
    if (chatState.config.saving) return t("settings.plugin.ai_chat.action.saving");
    if (isUnsaved()) return t("settings.plugin.ai_chat.action.save_required");
    return t("settings.plugin.ai_chat.action.save");
  });

  return (
    <SettingsPanel
      title={t("settings.plugin.ai_chat.title")}
      description={t("settings.plugin.ai_chat.description")}
      action={
        <SettingsToolbarAction
          variant="primary"
          disabled={chatState.config.saving}
          class={isUnsaved() ? "ring-2 ring-warning/60 ring-offset-1 ring-offset-bg-primary" : ""}
          onClick={() => void saveSettingsDraft()}
        >
          {saveButtonLabel()}
        </SettingsToolbarAction>
      }
    >
      <Show when={isUnsaved()}>
        <SettingsBanner
          tone="warning"
          title={t("settings.plugin.ai_chat.unsaved.title")}
          description={t("settings.plugin.ai_chat.unsaved.description")}
        />
      </Show>

      <SettingsBanner
        tone="info"
        class="select-text"
        title={t("settings.plugin.ai_chat.guide.title")}
        description={
          <ol class="mt-1.5 list-decimal space-y-1.5 pl-4 text-xs/relaxed text-text-secondary">
            <li>
              <strong class="text-text-primary">
                {t("settings.plugin.ai_chat.guide.connection_label")}
              </strong>{" "}
              {t(guideCopy().connection)}
            </li>
            <li>
              <strong class="text-text-primary">
                {t("settings.plugin.ai_chat.guide.save_label")}
              </strong>{" "}
              {t(guideCopy().save)}
            </li>
            <li>
              <strong class="text-text-primary">
                {t("settings.plugin.ai_chat.guide.open_chat_label")}
              </strong>{" "}
              {t(guideCopy().openChat)}
            </li>
          </ol>
        }
      />

      <SettingsBanner
        tone="info"
        class="select-text"
        title={t("settings.plugin.ai_chat.account_banner.title")}
        description={t("settings.plugin.ai_chat.account_banner.description")}
        action={
          <SettingsToolbarAction variant="primary" onClick={openAccountSettings}>
            {t("settings.plugin.ai_chat.account_banner.open_account")}
          </SettingsToolbarAction>
        }
      />

      <SettingsFieldRow
        label={t("settings.plugin.ai_chat.connection.label")}
        description={t("settings.plugin.ai_chat.connection.description")}
        control={
          <div class="w-full max-w-72">
            <SettingsSelect
              options={providerOptions()}
              value={chatState.config.settingsDraft.provider}
              onChange={(value) => setSettingsDraft({ provider: value as AiProvider })}
            />
          </div>
        }
      />

      <Show when={chatState.config.settingsDraft.provider === "remote"}>
        <SettingsFieldRow
          label={t("settings.plugin.ai_chat.model.label")}
          description={t("settings.plugin.ai_chat.model.remote_description")}
          control={
            <div class="w-full max-w-sm">
              <SettingsInput
                type="text"
                value={shortModelLabel(chatState.config.model)}
                readOnly
                class="text-text-secondary"
              />
            </div>
          }
        />
        <SettingsBanner
          tone="info"
          class="py-2.5!"
          title={t("settings.plugin.ai_chat.remote_banner.title")}
          description={t("settings.plugin.ai_chat.remote_banner.description")}
        />
      </Show>

      <Show when={chatState.config.settingsDraft.provider === "gemini"}>
        <SettingsBanner
          tone="info"
          class="py-2.5! select-text"
          title={t("settings.plugin.ai_chat.gemini_banner.title")}
          description={
            <ol class="mt-1.5 list-decimal space-y-1.5 pl-4 text-[0.75rem] text-text-secondary">
              <li>{t("settings.plugin.ai_chat.gemini_banner.step1")}</li>
              <li>{t("settings.plugin.ai_chat.gemini_banner.step2")}</li>
              <li>{t("settings.plugin.ai_chat.gemini_banner.step3")}</li>
            </ol>
          }
        />
        <SettingsFieldRow
          stacked
          label={t("settings.plugin.ai_chat.api_key.label_gemini")}
          description={t("settings.plugin.ai_chat.api_key.description")}
          control={
            <div data-settings-anchor="api-key" class="w-full max-w-md">
              <ApiKeyInput
                value={chatState.config.settingsDraft.apiKey}
                visible={showGeminiApiKey()}
                setVisible={setShowGeminiApiKey}
                onInput={(apiKey) => setSettingsDraft({ apiKey })}
              />
            </div>
          }
        />
        <SettingsFieldRow
          label={t("settings.plugin.ai_chat.model.label")}
          description={t("settings.plugin.ai_chat.model.gemini_description")}
          control={
            <div class="w-full max-w-sm">
              <SettingsInput
                type="text"
                value={shortModelLabel(chatState.config.model)}
                readOnly
                class="text-text-secondary"
              />
            </div>
          }
        />
      </Show>

      <Show when={chatState.config.settingsDraft.provider === "openai"}>
        <SettingsFieldRow
          stacked
          label={t("settings.plugin.ai_chat.openai_base_url.label")}
          description={t("settings.plugin.ai_chat.openai_base_url.description")}
          control={
            <div class="w-full max-w-md">
              <SettingsInput
                type="url"
                value={chatState.config.settingsDraft.openaiBaseUrl}
                placeholder={t("settings.plugin.ai_chat.openai_base_url.placeholder")}
                spellcheck={false}
                onInput={(event) => setSettingsDraft({ openaiBaseUrl: event.currentTarget.value })}
              />
            </div>
          }
        />
        <SettingsFieldRow
          stacked
          label={`${t("settings.plugin.ai_chat.api_key.label_openai")} (${t(
            openAiKeyRequirement() === "required"
              ? "settings.plugin.ai_chat.api_key.requirement_required"
              : "settings.plugin.ai_chat.api_key.requirement_optional",
          )})`}
          description={t("settings.plugin.ai_chat.api_key.description")}
          control={
            <div data-settings-anchor="api-key" class="w-full max-w-md">
              <ApiKeyInput
                value={chatState.config.settingsDraft.openaiApiKey}
                visible={showOpenAiApiKey()}
                setVisible={setShowOpenAiApiKey}
                onInput={(openaiApiKey) => setSettingsDraft({ openaiApiKey })}
              />
            </div>
          }
        />
        <Show
          when={
            openAiKeyRequirement() === "required" &&
            normalizeApiKey(chatState.config.settingsDraft.openaiApiKey) === null
          }
        >
          <SettingsBanner
            tone="warning"
            title={t("settings.plugin.ai_chat.openai_banner.key_title")}
            description={t("settings.plugin.ai_chat.openai_banner.key_description")}
          />
        </Show>
        <SettingsFieldRow
          stacked
          label={t("settings.plugin.ai_chat.model.label")}
          description={t("settings.plugin.ai_chat.model.openai_description")}
          control={
            <div class="flex w-full max-w-md items-center gap-2">
              <SettingsInput
                type="text"
                list="kuku-openai-models"
                value={chatState.config.settingsDraft.openaiModel}
                placeholder={t("settings.plugin.ai_chat.model.openai_placeholder")}
                spellcheck={false}
                onInput={(event) => setSettingsDraft({ openaiModel: event.currentTarget.value })}
              />
              <datalist id="kuku-openai-models">
                <For each={chatState.config.modelSuggestions}>
                  {(model) => <option value={model} />}
                </For>
              </datalist>
              <SettingsToolbarAction
                disabled={chatState.config.modelsLoading}
                onClick={() => void loadModelSuggestions()}
              >
                {chatState.config.modelsLoading
                  ? t("settings.plugin.ai_chat.models.loading")
                  : t("settings.plugin.ai_chat.models.load")}
              </SettingsToolbarAction>
            </div>
          }
        />
        <Show when={chatState.config.settingsDraft.openaiModel.trim().length === 0}>
          <SettingsBanner
            tone="warning"
            title={t("settings.plugin.ai_chat.openai_banner.model_title")}
            description={t("settings.plugin.ai_chat.openai_banner.model_description")}
          />
        </Show>
        <Show when={chatState.config.modelsError}>
          {(error) => <SettingsBanner tone="error" description={error()} />}
        </Show>
      </Show>

      <Show when={chatState.config.error}>
        {(error) => <SettingsBanner tone="error" description={error()} />}
      </Show>
      <Show when={chatState.config.toolsError}>
        {(error) => <SettingsBanner tone="error" description={error()} />}
      </Show>

      <SettingsCard
        title={t("settings.plugin.ai_chat.tools.title")}
        description={t("settings.plugin.ai_chat.tools.description")}
        tone="subtle"
      >
        <Show when={chatState.config.toolsLoading}>
          <p class="text-[0.75rem] text-text-muted">{t("settings.plugin.ai_chat.tools.loading")}</p>
        </Show>
        <Show when={!chatState.config.toolsLoading && chatState.config.availableTools.length > 0}>
          <p class="text-[0.75rem] text-text-muted">
            {chatState.config.availableTools.length === 1
              ? t("settings.plugin.ai_chat.tools.count_one")
              : tf("settings.plugin.ai_chat.tools.count_other", {
                  count: chatState.config.availableTools.length,
                })}
          </p>
          <details class="kuku-ai-tools-details mt-3 overflow-hidden rounded-sm border border-border/90 bg-bg-secondary/50 transition-shadow hover:border-border">
            <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-2.5 pr-2 text-left select-none marker:content-none [&::-webkit-details-marker]:hidden">
              <span class="flex min-w-0 items-center gap-2.5">
                <span class="flex size-6 shrink-0 items-center justify-center rounded-xs border border-border/80 bg-bg-elevated/80 text-icon">
                  <ChevronIcon
                    size={14}
                    class="kuku-ai-tools-chevron transition-transform duration-200"
                  />
                </span>
                <span>
                  <span class="block text-[0.8125rem] font-medium text-text-primary">
                    {t("settings.plugin.ai_chat.tools.summary_title")}
                  </span>
                  <span class="block text-[0.6875rem] text-text-muted">
                    {t("settings.plugin.ai_chat.tools.summary_hint")}
                  </span>
                </span>
              </span>
              <span class="shrink-0 rounded-xs border border-border/60 bg-bg-tertiary/80 px-2 py-0.5 text-[0.625rem] font-medium tracking-wide text-text-secondary uppercase">
                {t("settings.plugin.ai_chat.tools.tap")}
              </span>
            </summary>
            <div class="border-t border-border/50 bg-bg-primary/50 px-2.5 py-2">
              <ScrollArea axis="y" class="max-h-48 select-text">
                <div class="space-y-0.5 pr-0.5">
                  <For each={chatState.config.availableTools}>
                    {(tool) => {
                      const identity = () => formatToolIdentity(tool.toolId, tool.name);
                      const info = () => getToolInfo(tool.toolId ?? tool.name);
                      const showIdentity = () => identity() !== info().label;
                      return (
                        <SettingsListRow
                          title={<span class="text-[0.75rem]">{info().label}</span>}
                          description={
                            <span class="block space-y-1">
                              <span class="block text-[0.65rem] leading-snug text-text-secondary">
                                {info().description}
                              </span>
                              <Show when={showIdentity()}>
                                <span class="block font-mono text-[0.6rem] whitespace-pre-wrap text-text-muted/90">
                                  {identity()}
                                </span>
                              </Show>
                            </span>
                          }
                        />
                      );
                    }}
                  </For>
                </div>
              </ScrollArea>
            </div>
          </details>
        </Show>
        <Show when={!chatState.config.toolsLoading && chatState.config.availableTools.length === 0}>
          <SettingsBanner tone="info" description={t("settings.plugin.ai_chat.tools.empty")} />
        </Show>
      </SettingsCard>
    </SettingsPanel>
  );
}

export { AiSettings };
