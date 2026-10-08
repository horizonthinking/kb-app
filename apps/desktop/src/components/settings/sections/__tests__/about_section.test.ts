import { describe, expect, it } from "vitest";

import { updateChannelLabelFor } from "../update_channel_label";

describe("About update channel label", () => {
  it("updateChannelLabelFor returns the Homebrew key only for disabled builds", () => {
    expect(updateChannelLabelFor("kuku-updater-disabled", "h4.1")).toBe(
      "settings.about.updates_via_homebrew",
    );
    expect(updateChannelLabelFor("kuku-updater-enabled", "h4.1")).toBeNull();
    expect(updateChannelLabelFor("kuku-updater-disabled", "")).toBeNull();
  });
});
