import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmod,
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const scriptPath = path.join(repositoryRoot, "scripts", "bump-plugin-versions.mjs");

async function createFixture(testContext, versions = ["1.2.3", "1.2.3"]) {
  const root = await mkdtemp(path.join(os.tmpdir(), "plugin-versions-"));
  testContext.after(() => rm(root, { recursive: true, force: true }));

  const fixtureScriptPath = path.join(root, "scripts", "bump-plugin-versions.mjs");
  const cwd = path.join(root, "elsewhere", "deep");
  const plugins = ["alpha", "omega"].map((name, index) => ({
    manifest: {
      name,
      version: versions[index],
      description: `${name} description must survive`,
      keywords: ["one", "two"],
      interface: { displayName: name.toUpperCase(), capabilities: ["Write"] },
      "x-test-metadata": { enabled: true },
    },
    manifestPath: path.join(root, "plugins", name, ".codex-plugin", "plugin.json"),
  }));

  await Promise.all([
    mkdir(path.dirname(fixtureScriptPath), { recursive: true }),
    mkdir(cwd, { recursive: true }),
    mkdir(path.join(root, "plugins", "ignored-directory"), { recursive: true }),
    ...plugins.map(({ manifestPath }) => mkdir(path.dirname(manifestPath), { recursive: true })),
  ]);
  await copyFile(scriptPath, fixtureScriptPath);
  await writeFile(path.join(root, "VERSION"), "1.2.3\n");
  await Promise.all(
    plugins.map(({ manifest, manifestPath }) =>
      writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`),
    ),
  );

  return { cwd, plugins, root, scriptPath: fixtureScriptPath };
}

function runCli(fixture, ...arguments_) {
  return spawnSync(process.execPath, [fixture.scriptPath, ...arguments_], {
    cwd: fixture.cwd,
    encoding: "utf8",
  });
}

async function snapshotManagedFiles(fixture) {
  const paths = [
    path.join(fixture.root, "VERSION"),
    ...fixture.plugins.map(({ manifestPath }) => manifestPath),
  ];
  return new Map(
    await Promise.all(
      paths.map(async (filePath) => [filePath, await readFile(filePath, "utf8")]),
    ),
  );
}

async function assertManagedFilesEqual(snapshot) {
  for (const [filePath, expected] of snapshot) {
    assert.equal(await readFile(filePath, "utf8"), expected, filePath);
  }
}

test("--check succeeds when repository plugin versions match VERSION", () => {
  // Given: the tracked repository is the version-management fixture.
  // When: the CLI checks the lockstep version contract.
  const result = spawnSync(process.execPath, [scriptPath, "--check"], {
    cwd: repositoryRoot,
    encoding: "utf8",
  });

  // Then: the check succeeds without reporting an error.
  assert.equal(result.status, 0, result.stderr);
});

test("patch discovers every plugin from any cwd and preserves manifest data", async (testContext) => {
  // Given: two synchronized plugins and an unrelated directory without a manifest.
  const fixture = await createFixture(testContext);
  const originals = structuredClone(fixture.plugins.map(({ manifest }) => manifest));

  // When: patch is invoked from a nested directory outside the repository root.
  const result = runCli(fixture, "patch");

  // Then: VERSION and every discovered manifest advance while other data survives.
  assert.equal(result.status, 0, result.stderr);
  assert.equal(await readFile(path.join(fixture.root, "VERSION"), "utf8"), "1.2.4\n");
  for (const [index, { manifestPath }] of fixture.plugins.entries()) {
    const updated = JSON.parse(await readFile(manifestPath, "utf8"));
    assert.deepEqual(updated, { ...originals[index], version: "1.2.4" });
  }
});

for (const [argument, expected] of [
  ["minor", "1.3.0"],
  ["major", "2.0.0"],
  ["7.8.9", "7.8.9"],
]) {
  test(`${argument} sets the expected lockstep version`, async (testContext) => {
    // Given: a synchronized plugin repository at version 1.2.3.
    const fixture = await createFixture(testContext);

    // When: the requested version change is applied.
    const result = runCli(fixture, argument);

    // Then: the canonical version and every manifest match the expected version.
    assert.equal(result.status, 0, result.stderr);
    assert.equal((await readFile(path.join(fixture.root, "VERSION"), "utf8")).trim(), expected);
    for (const { manifestPath } of fixture.plugins) {
      assert.equal(JSON.parse(await readFile(manifestPath, "utf8")).version, expected);
    }
  });
}

test("--check does not rewrite synchronized files", async (testContext) => {
  // Given: synchronized files captured byte for byte.
  const fixture = await createFixture(testContext);
  const before = await snapshotManagedFiles(fixture);

  // When: lockstep consistency is checked.
  const result = runCli(fixture, "--check");

  // Then: the command succeeds and every managed file remains unchanged.
  assert.equal(result.status, 0, result.stderr);
  await assertManagedFilesEqual(before);
});

test("a version change refuses drift without writing any file", async (testContext) => {
  // Given: one manifest is behind VERSION and all managed files are captured.
  const fixture = await createFixture(testContext, ["1.2.3", "1.2.2"]);
  const before = await snapshotManagedFiles(fixture);

  // When: a minor version change is requested.
  const result = runCli(fixture, "minor");

  // Then: the drift is located and no managed file is modified.
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /omega.*expected 1\.2\.3, found 1\.2\.2/s);
  await assertManagedFilesEqual(before);
});

test("a staging failure leaves every managed file unchanged", async (testContext) => {
  // Given: synchronized files and one manifest directory that cannot accept staged files.
  const fixture = await createFixture(testContext);
  const protectedDirectory = path.dirname(fixture.plugins[1].manifestPath);
  const before = await snapshotManagedFiles(fixture);
  await chmod(protectedDirectory, 0o555);

  // When: a patch version change is requested.
  let result;
  try {
    result = runCli(fixture, "patch");
  } finally {
    await chmod(protectedDirectory, 0o755);
  }

  // Then: the staging error is reported and no managed file is modified.
  assert.notEqual(result.status, 0);
  await assertManagedFilesEqual(before);
});

for (const invalidVersion of ["1.2", "v1.2.3", "1.2.3-beta", "01.2.3"]) {
  test(`invalid target ${invalidVersion} is rejected without writing`, async (testContext) => {
    // Given: synchronized files captured before an invalid request.
    const fixture = await createFixture(testContext);
    const before = await snapshotManagedFiles(fixture);

    // When: a non-stable SemVer target is requested.
    const result = runCli(fixture, invalidVersion);

    // Then: the CLI explains the accepted format and leaves files untouched.
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /stable SemVer X\.Y\.Z/);
    await assertManagedFilesEqual(before);
  });
}

test("invalid manifest JSON reports its path without writing", async (testContext) => {
  // Given: one plugin manifest contains malformed JSON.
  const fixture = await createFixture(testContext);
  const brokenPath = fixture.plugins[1].manifestPath;
  await writeFile(brokenPath, "{broken\n");
  const before = await snapshotManagedFiles(fixture);

  // When: a patch change is requested.
  const result = runCli(fixture, "patch");

  // Then: the manifest path is reported and no managed file is modified.
  assert.notEqual(result.status, 0);
  assert.ok(result.stderr.includes(brokenPath), result.stderr);
  assert.match(result.stderr, /invalid JSON/);
  await assertManagedFilesEqual(before);
});
