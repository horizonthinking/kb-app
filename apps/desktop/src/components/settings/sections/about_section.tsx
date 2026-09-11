import { getVersion } from "@tauri-apps/api/app";
import { createSignal, onMount } from "solid-js";

import { SettingsMetricRow, SettingsPanel } from "~/components/settings/settings_blocks";
import { t, tf } from "~/i18n";
import { UPDATER_BUILD_MARKER } from "~/stores/updater";

import { updateChannelLabelFor } from "./update_channel_label";

function AboutSection() {
  const [version, setVersion] = createSignal(t("settings.about.version.loading"));
  const buildLabel = import.meta.env.VITE_KUKU_BUILD_LABEL ?? "";
  const updateChannelKey = updateChannelLabelFor(UPDATER_BUILD_MARKER, buildLabel);
  const versionLabel = () =>
    updateChannelKey
      ? `${version()} (${tf("settings.about.h4_build", { label: buildLabel })}), ${t(updateChannelKey)}`
      : version();

  onMount(() => {
    void getVersion()
      .then((value) => setVersion(value))
      .catch(() => setVersion(t("settings.about.version.unknown")));
  });

  return (
    <SettingsPanel
      title={t("settings.about.title")}
      description={t("settings.about.description")}
      anchor="about"
    >
      <div class="space-y-2">
        <SettingsMetricRow label={t("settings.about.metric.version")} value={versionLabel()} />
        <SettingsMetricRow label={t("settings.about.metric.license")} value="MIT" />
      </div>
    </SettingsPanel>
  );
}

export { AboutSection };
