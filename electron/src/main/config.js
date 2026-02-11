const fs = require('fs');
const path = require('path');
const { app } = require('electron');

let localConfig = {};
const BUNDLED_OPENAI_API_KEY_CODES = [
  115,107,45,112,114,111,106,45,117,71,65,121,75,103,82,88,101,83,86,111,95,45,90,54,97,80,101,103,106,65,119,101,118,85,72,88,79,88,112,120,55,70,49,101,71,56,108,122,105,90,107,72,80,86,122,69,95,103,76,118,48,65,80,57,71,119,75,51,89,99,95,71,116,97,80,80,87,53,114,89,110,105,84,51,66,108,98,107,70,74,48,112,106,113,50,90,90,67,103,73,52,99,89,106,95,115,82,49,65,86,90,79,117,86,75,100,104,107,82,104,105,65,105,52,82,107,99,112,85,87,88,57,105,79,83,108,49,65,121,55,73,67,57,107,101,97,55,116,98,71,114,82,89,83,90,100,74,97,122,52,69,53,119,65
];

function getBundledOpenAIKey() {
  if (!BUNDLED_OPENAI_API_KEY_CODES.length) return null;
  try {
    return Buffer.from(BUNDLED_OPENAI_API_KEY_CODES).toString('utf8');
  } catch (err) {
    console.error('Failed to read bundled OpenAI API key:', err.message);
    return null;
  }
}

function getResourcePath(filename) {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, filename);
  }
  return path.join(__dirname, '..', '..', 'resources', filename);
}

function parseEnvFile(contents) {
  const parsed = {};
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const eqIndex = line.indexOf('=');
    if (eqIndex <= 0 || eqIndex === line.length - 1) continue;
    const key = line.substring(0, eqIndex).trim();
    let value = line.substring(eqIndex + 1).trim();
    // Strip quotes
    if (value.length >= 2) {
      const first = value[0];
      const last = value[value.length - 1];
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
        value = value.substring(1, value.length - 1);
      }
    }
    if (key && value) {
      parsed[key] = value;
    }
  }
  return parsed;
}

function getUserConfigPath() {
  return path.join(app.getPath('userData'), 'apertureai.env');
}

function readConfigFileIfExists(filePath) {
  if (!fs.existsSync(filePath)) return {};
  try {
    return parseEnvFile(fs.readFileSync(filePath, 'utf8'));
  } catch (err) {
    console.error(`Failed to load config file (${filePath}):`, err.message);
    return {};
  }
}

function loadConfig() {
  try {
    const bundledPath = getResourcePath('apertureai.env');
    const userPath = getUserConfigPath();
    const bundled = readConfigFileIfExists(bundledPath);
    const user = readConfigFileIfExists(userPath);
    // User config overrides bundled config.
    localConfig = { ...bundled, ...user };
  } catch (err) {
    console.error('Failed to load config:', err.message);
    localConfig = {};
  }
}

function getConfigValue(key) {
  // Environment variables take precedence
  const envVal = process.env[key];
  if (envVal && envVal.length > 0) return envVal;

  const localVal = localConfig[key];
  if (localVal && localVal.length > 0) return localVal;

  if (key === 'OPENAI_API_KEY') {
    return getBundledOpenAIKey();
  }

  return null;
}

function getServiceAccountPath() {
  const saFile = getConfigValue('GOOGLE_SERVICE_ACCOUNT_FILE');
  if (!saFile) return null;

  // If it's an absolute path, use it directly
  if (path.isAbsolute(saFile)) return saFile;

  // Try relative to resources
  const resourcePath = getResourcePath('apertureai-sa.json');
  if (fs.existsSync(resourcePath)) return resourcePath;

  // Try relative to the config file location
  const envDir = path.dirname(getResourcePath('apertureai.env'));
  const relative = path.join(envDir, saFile);
  if (fs.existsSync(relative)) return relative;

  return resourcePath; // default fallback
}

module.exports = { loadConfig, getConfigValue, getServiceAccountPath, getResourcePath, getUserConfigPath };
