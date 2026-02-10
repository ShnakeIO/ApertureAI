let autoUpdater;

try {
  autoUpdater = require('electron-updater').autoUpdater;
} catch (e) {
  autoUpdater = null;
}
const { app } = require('electron');
const { getConfigValue } = require('./config');

const UPDATE_CHECK_INTERVAL_MS = 5000;
let updateCheckTimer = null;
let isChecking = false;
let isDownloadComplete = false;
let statusWindow = null;

const updaterState = {
  enabled: false,
  state: autoUpdater ? 'idle' : 'disabled',
  message: autoUpdater ? 'Updater ready.' : 'electron-updater is unavailable.',
  checkIntervalMs: UPDATE_CHECK_INTERVAL_MS,
  currentVersion: null,
  availableVersion: null,
  checkCount: 0,
  isChecking: false,
  hasGitHubToken: false,
  lastCheckStartedAt: null,
  lastCheckCompletedAt: null,
  downloadPercent: null,
  lastError: null,
  lastErrorAt: null
};

function isoNow() {
  return new Date().toISOString();
}

function getUpdaterStatus() {
  return { ...updaterState };
}

function emitStatus() {
  if (!statusWindow || statusWindow.isDestroyed()) return;
  statusWindow.webContents.send('update:status', getUpdaterStatus());
}

function updateState(patch) {
  Object.assign(updaterState, patch);
  emitStatus();
}

function getGitHubToken() {
  const token = (getConfigValue('GITHUB_TOKEN') || getConfigValue('GH_TOKEN') || '').trim();
  if (!token) return null;
  // Ignore placeholder values so we don't send invalid auth headers forever.
  if (token.includes('YOUR_GITHUB_TOKEN')) return null;
  return token;
}

function configureAuthHeader() {
  if (!autoUpdater) return;
  const token = getGitHubToken();
  if (token) {
    autoUpdater.requestHeaders = { Authorization: `token ${token}` };
    updateState({ hasGitHubToken: true });
    return;
  }
  autoUpdater.requestHeaders = {};
  updateState({ hasGitHubToken: false });
}

function normalizeUpdaterError(err) {
  const message = err?.message || 'Unknown updater error.';
  const lower = message.toLowerCase();
  if (
    lower.includes('releases.atom') &&
    lower.includes('404') &&
    (lower.includes('authentication token') || lower.includes('double check'))
  ) {
    return 'This app build is configured for private GitHub updates. Install the latest public-release build manually once (v1.0.4+) or set GITHUB_TOKEN if you keep private mode.';
  }
  if (
    lower.includes('code signature') &&
    lower.includes('did not pass validation') &&
    lower.includes('code has no resources')
  ) {
    return 'Downloaded app has invalid macOS signature. Publish a build with valid signing (ad-hoc or Developer ID). Update to v1.0.2+ fixes this packaging issue.';
  }
  if (
    lower.includes('code signature') &&
    lower.includes('did not pass validation') &&
    lower.includes('code failed to satisfy specified code requirement')
  ) {
    return 'Current installed app has an incompatible signature requirement for auto-update. Install the latest release manually once (v1.0.3+), then future in-app updates will work.';
  }
  return message;
}

async function runUpdateCheck() {
  if (!autoUpdater || isChecking || isDownloadComplete || !updaterState.enabled) return;
  isChecking = true;
  const startedAt = isoNow();
  updateState({
    state: 'checking',
    message: 'Checking GitHub for updates...',
    checkCount: updaterState.checkCount + 1,
    isChecking: true,
    lastCheckStartedAt: startedAt,
    lastError: null
  });

  try {
    await autoUpdater.checkForUpdates();
  } catch (err) {
    const normalized = normalizeUpdaterError(err);
    console.error('Update check failed:', normalized);
    updateState({
      state: 'error',
      message: 'Update check failed.',
      lastError: normalized,
      lastErrorAt: isoNow()
    });
  } finally {
    isChecking = false;
    const patch = {
      isChecking: false,
      lastCheckCompletedAt: isoNow()
    };
    if (updaterState.state === 'checking') {
      patch.state = 'idle';
      patch.message = 'Update check completed.';
    }
    updateState(patch);
  }
}

function initAutoUpdater(mainWindow) {
  statusWindow = mainWindow;
  updateState({
    currentVersion: app.getVersion()
  });

  if (!autoUpdater) {
    console.log('electron-updater not available, skipping auto-update.');
    updateState({
      enabled: false,
      state: 'disabled',
      message: 'Auto-update unavailable: electron-updater failed to load.'
    });
    return;
  }

  if (!app.isPackaged) {
    updateState({
      enabled: false,
      state: 'disabled',
      message: 'Auto-update disabled in development mode. Install a packaged app build to test updates.'
    });
    return;
  }

  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  configureAuthHeader();
  isDownloadComplete = false;
  updateState({
    enabled: true,
    state: 'idle',
    message: updaterState.hasGitHubToken
      ? 'Auto-update enabled. Auth token loaded. Waiting for next check.'
      : 'Auto-update enabled. Waiting for next check.',
    availableVersion: null,
    downloadPercent: null,
    lastError: null
  });

  autoUpdater.removeAllListeners('update-available');
  autoUpdater.removeAllListeners('download-progress');
  autoUpdater.removeAllListeners('update-downloaded');
  autoUpdater.removeAllListeners('update-not-available');
  autoUpdater.removeAllListeners('error');

  autoUpdater.on('update-available', (info) => {
    updateState({
      state: 'downloading',
      message: `Update v${info.version} found. Downloading...`,
      availableVersion: info.version,
      downloadPercent: 0,
      lastError: null
    });
    mainWindow.webContents.send('update:available', info.version);
  });

  autoUpdater.on('download-progress', (progress) => {
    const pct = Number(progress?.percent || 0);
    updateState({
      state: 'downloading',
      message: `Downloading update... ${pct.toFixed(1)}%`,
      downloadPercent: pct
    });
  });

  autoUpdater.on('update-downloaded', (info) => {
    isDownloadComplete = true;
    updateState({
      state: 'ready',
      message: `Update v${info.version} is ready to install.`,
      availableVersion: info.version,
      downloadPercent: 100,
      isChecking: false,
      lastError: null
    });
    mainWindow.webContents.send('update:downloaded', info.version);
  });

  autoUpdater.on('update-not-available', () => {
    updateState({
      state: 'up_to_date',
      message: 'Connected to GitHub. App is up to date.',
      availableVersion: null,
      downloadPercent: null
    });
    mainWindow.webContents.send('update:not-available');
  });

  autoUpdater.on('error', (err) => {
    const normalized = normalizeUpdaterError(err);
    console.error('Auto-update error:', normalized);
    updateState({
      state: 'error',
      message: 'Auto-update error.',
      lastError: normalized,
      lastErrorAt: isoNow(),
      isChecking: false
    });
  });

  // Check immediately at startup, then keep checking every 5 seconds while app is open.
  runUpdateCheck();

  if (updateCheckTimer) {
    clearInterval(updateCheckTimer);
  }
  updateCheckTimer = setInterval(() => {
    runUpdateCheck();
  }, UPDATE_CHECK_INTERVAL_MS);
}

function quitAndInstall() {
  if (autoUpdater) {
    autoUpdater.quitAndInstall(false, true);
  }
}

function stopAutoUpdater() {
  if (updateCheckTimer) {
    clearInterval(updateCheckTimer);
    updateCheckTimer = null;
  }
}

module.exports = { initAutoUpdater, quitAndInstall, stopAutoUpdater, getUpdaterStatus };
