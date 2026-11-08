import { useState } from "react";
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import { afterEach, expect, it } from "vitest";
import { RolesEditor } from "./RoutingEditor";
import { builtInRoles, type RouteSettings } from "./api";

afterEach(cleanup);

function Editor({ initial = {} }: { initial?: Partial<RouteSettings> }) {
  const [settings, setSettings] = useState<RouteSettings>({ algorithm: "noop", efficientModel: "test", capableModel: "test", ...initial });
  return <RolesEditor settings={settings} change={(patch) => setSettings((previous) => ({ ...previous, ...patch }))} disabled={false} />;
}

it("keeps the selected role visible when a search has no matches", () => {
  render(<Editor />);
  const selectedName = (screen.getByLabelText("Role name") as HTMLInputElement).value;
  fireEvent.change(screen.getByLabelText("Search roles"), { target: { value: "no-such-role" } });
  expect(screen.getByText("No matching roles")).toBeTruthy();
  expect(screen.getByText(/This role is outside the current filters/)).toBeTruthy();
  expect(screen.getByLabelText("Role name")).toHaveProperty("value", selectedName);
  fireEvent.click(screen.getByRole("button", { name: "Clear filters" }));
  expect(screen.queryByText("No matching roles")).toBeNull();
});

it("clears filters when creating a role and retains edits when switching", () => {
  render(<Editor />);
  fireEvent.change(screen.getByLabelText("Search roles"), { target: { value: "hidden" } });
  fireEvent.click(screen.getByRole("button", { name: "New role" }));
  expect(document.activeElement).toBe(screen.getByLabelText("Role name"));
  expect(screen.getByLabelText("Search roles")).toHaveProperty("value", "");
  fireEvent.change(screen.getByLabelText("Role name"), { target: { value: "Review code" } });
  fireEvent.change(screen.getByLabelText("Model system prompt"), { target: { value: "Find bugs." } });
  const list = within(screen.getByLabelText("Roles"));
  fireEvent.click(list.getByRole("button", { name: /^Classifier/ }));
  fireEvent.click(list.getByRole("button", { name: /^Review code/ }));
  expect(screen.getByLabelText("Model system prompt")).toHaveProperty("value", "Find bugs.");
});

it("requires confirmation before deleting a custom role and handles an empty library", () => {
  render(<Editor initial={{ roles: [] }} />);
  expect(screen.getByText("Your library is empty")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Create first role" }));
  fireEvent.click(screen.getByRole("button", { name: "Delete role" }));
  expect(screen.getByLabelText("Role name")).toBeTruthy();
  fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
  expect(screen.queryByRole("button", { name: "Confirm delete" })).toBeNull();
  fireEvent.click(screen.getByRole("button", { name: "Delete role" }));
  fireEvent.click(screen.getByRole("button", { name: "Confirm delete" }));
  expect(screen.getByText("Your library is empty")).toBeTruthy();
});

it("protects assigned roles and resets only after confirmation", () => {
  render(<Editor />);
  expect(screen.getByLabelText("Role kind")).toHaveProperty("disabled", true);
  expect(screen.getByRole("button", { name: "Delete role" })).toHaveProperty("disabled", true);
  fireEvent.change(screen.getByLabelText("Role name"), { target: { value: "Changed classifier" } });
  fireEvent.click(screen.getByRole("button", { name: "Reset role" }));
  expect(screen.getByLabelText("Role name")).toHaveProperty("value", "Changed classifier");
  fireEvent.click(screen.getByRole("button", { name: "Confirm reset" }));
  expect(screen.getByLabelText("Role name")).toHaveProperty("value", builtInRoles[0].name);
});
