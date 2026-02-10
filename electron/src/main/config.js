const fs = require('fs');
const path = require('path');
const { app } = require('electron');

let localConfig = {};

function getResourcePath(filename) {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, filename);
  }
  return path.join(__dirname, '..', '..', 'resources', filename);
}

function loadConfig() {
  const envPath = getResourcePath('apertureai.env');
  try {
    const contents = fs.readFileSync(envPath, 'utf8');
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
    localConfig = parsed;
  } catch (err) {
    console.error('Failed to load config:', err.message);
    localConfig = {};
  }
}

function getConfigValue(key) {
  // Environment variables take precedence
  const envVal = process.env[key];
  if (envVal && envVal.length > 0) return envVal;
  return localConfig[key] || null;
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

module.exports = { loadConfig, getConfigValue, getServiceAccountPath, getResourcePath };
