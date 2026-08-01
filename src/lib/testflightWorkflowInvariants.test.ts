import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const workflow = readFileSync(
  join(import.meta.dirname, "..", "..", ".github", "workflows", "testflight.yml"),
  "utf8",
);

describe("TestFlight workflow production-backend invariant", () => {
  it("only accepts main for automatic and manually dispatched builds", () => {
    expect(workflow).toContain("branches: [main]");
    expect(workflow).not.toContain("branches: [staging]");
    expect(workflow).toContain('if [ "$GITHUB_REF" != "refs/heads/main" ]');
    expect(workflow).toContain("TestFlight builds must run from main");
  });

  it("lets a main workflow dispatch request the paid beta job directly", () => {
    expect(workflow).toContain('if [ "$EVENT_NAME" = "workflow_dispatch" ]');
    expect(workflow).toContain('echo "build=true" >>"$GITHUB_OUTPUT"');
    expect(workflow).toContain("if: needs.gate.outputs.build == 'true'");
  });
});
