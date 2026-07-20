import { mkdtemp, open, readFile, readdir, rename, rm } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const stableSemverPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function usageError() {
  return new Error(
    "Usage: node scripts/bump-plugin-versions.mjs <patch|minor|major|X.Y.Z|--check>",
  );
}

function parseStableVersion(value, source) {
  const match = stableSemverPattern.exec(value);
  if (match === null) {
    throw new Error(`${source}: expected stable SemVer X.Y.Z, found ${JSON.stringify(value)}`);
  }

  return {
    major: BigInt(match[1]),
    minor: BigInt(match[2]),
    patch: BigInt(match[3]),
    value,
  };
}

async function discoverManifests(root) {
  const pluginsRoot = path.join(root, "plugins");
  const entries = await readdir(pluginsRoot, { withFileTypes: true });
  const manifests = [];

  for (const entry of entries.sort((left, right) => left.name.localeCompare(right.name))) {
    if (!entry.isDirectory()) {
      continue;
    }

    const manifestPath = path.join(pluginsRoot, entry.name, ".codex-plugin", "plugin.json");
    try {
      const contents = await readFile(manifestPath, "utf8");
      let manifest;
      try {
        manifest = JSON.parse(contents);
      } catch (error) {
        throw new Error(`${manifestPath}: invalid JSON: ${error.message}`);
      }

      if (
        manifest === null ||
        Array.isArray(manifest) ||
        typeof manifest !== "object" ||
        typeof manifest.name !== "string" ||
        typeof manifest.version !== "string"
      ) {
        throw new Error(`${manifestPath}: manifest requires string name and version fields`);
      }

      manifests.push({ contents, manifestPath, manifest });
    } catch (error) {
      if (error.code === "ENOENT") {
        continue;
      }
      throw error;
    }
  }

  if (manifests.length === 0) {
    throw new Error(`${pluginsRoot}: no plugin manifests found`);
  }

  return manifests;
}

async function readState(root) {
  const versionPath = path.join(root, "VERSION");
  const versionContents = await readFile(versionPath, "utf8");
  const version = parseStableVersion(versionContents.trim(), versionPath);
  const manifests = await discoverManifests(root);

  for (const { manifestPath, manifest } of manifests) {
    const manifestVersion = parseStableVersion(manifest.version, manifestPath);
    if (manifestVersion.value !== version.value) {
      throw new Error(
        `${manifestPath}: expected ${version.value}, found ${manifestVersion.value}`,
      );
    }
  }

  return { manifests, version, versionContents, versionPath };
}

function resolveTargetVersion(command, currentVersion) {
  switch (command) {
    case "patch":
      return `${currentVersion.major}.${currentVersion.minor}.${currentVersion.patch + 1n}`;
    case "minor":
      return `${currentVersion.major}.${currentVersion.minor + 1n}.0`;
    case "major":
      return `${currentVersion.major + 1n}.0.0`;
    default:
      return parseStableVersion(command, "target version").value;
  }
}

async function writeSyncedFile(filePath, contents) {
  const file = await open(filePath, "wx");
  try {
    await file.writeFile(contents);
    await file.sync();
  } finally {
    await file.close();
  }
}

async function cleanupStagedUpdates(stagedUpdates) {
  await Promise.allSettled(
    stagedUpdates.map(({ temporaryDirectory }) =>
      rm(temporaryDirectory, { recursive: true, force: true }),
    ),
  );
}

async function writeState(state, targetVersion) {
  const updates = [
    {
      contents: `${targetVersion}\n`,
      filePath: state.versionPath,
      previousContents: state.versionContents,
    },
    ...state.manifests.map(({ contents, manifestPath, manifest }) => ({
      contents: `${JSON.stringify({ ...manifest, version: targetVersion }, null, 2)}\n`,
      filePath: manifestPath,
      previousContents: contents,
    })),
  ];
  const stagedUpdates = [];

  try {
    for (const update of updates) {
      const temporaryDirectory = await mkdtemp(
        path.join(path.dirname(update.filePath), ".plugin-version-"),
      );
      const stagedUpdate = {
        backupPath: path.join(temporaryDirectory, "previous"),
        filePath: update.filePath,
        stagedPath: path.join(temporaryDirectory, "next"),
        temporaryDirectory,
      };
      stagedUpdates.push(stagedUpdate);
      await writeSyncedFile(stagedUpdate.stagedPath, update.contents);
      await writeSyncedFile(stagedUpdate.backupPath, update.previousContents);
    }
  } catch (error) {
    await cleanupStagedUpdates(stagedUpdates);
    throw error;
  }

  const committedUpdates = [];
  let retainBackups = false;
  try {
    for (const stagedUpdate of stagedUpdates) {
      await rename(stagedUpdate.stagedPath, stagedUpdate.filePath);
      committedUpdates.push(stagedUpdate);
    }
  } catch (commitError) {
    const rollbackErrors = [];
    for (const committedUpdate of committedUpdates.reverse()) {
      try {
        await rename(committedUpdate.backupPath, committedUpdate.filePath);
      } catch (rollbackError) {
        rollbackErrors.push(rollbackError);
      }
    }

    if (rollbackErrors.length > 0) {
      retainBackups = true;
      const backupDirectories = stagedUpdates
        .map(({ temporaryDirectory }) => temporaryDirectory)
        .join(", ");
      throw new AggregateError(
        [commitError, ...rollbackErrors],
        `Version update and rollback failed; backups retained in ${backupDirectories}`,
      );
    }
    throw commitError;
  } finally {
    if (!retainBackups) {
      await cleanupStagedUpdates(stagedUpdates);
    }
  }
}

async function main() {
  const [command, ...extraArguments] = process.argv.slice(2);
  if (command === undefined || extraArguments.length > 0) {
    throw usageError();
  }

  const state = await readState(repositoryRoot);
  const { manifests, version } = state;
  if (command === "--check") {
    process.stdout.write(
      `All ${manifests.length} plugin manifests match VERSION ${version.value}.\n`,
    );
    return;
  }

  const targetVersion = resolveTargetVersion(command, version);
  if (targetVersion === version.value) {
    process.stdout.write(`All plugin manifests already use VERSION ${version.value}.\n`);
    return;
  }

  await writeState(state, targetVersion);
  process.stdout.write(
    `Updated ${manifests.length} plugin manifests: ${version.value} -> ${targetVersion}.\n`,
  );
}

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
