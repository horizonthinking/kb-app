import type { MessageKey } from "~/i18n";

function updateChannelLabelFor(marker: string, buildLabel: string): MessageKey | null {
  return marker.endsWith("-disabled") && buildLabel.trim().length > 0
    ? "settings.about.updates_via_homebrew"
    : null;
}

export { updateChannelLabelFor };
