let autoUpdater;

try {
  autoUpdater = require('electron-updater').autoUpdater;
} catch (e) {
  autoUpdater = null;
}

const UPDATE_CHECK_INTERVAL_MS = 5000;
let updateCheckTimer = null;
let isChecking = false;
let isDownloadComplete = false;

async function runUpdateCheck() {
  if (!autoUpdater || isChecking || isDownloadComplete) return;
  isChecking = true;
  try {
    await autoUpdater.checkForUpdates();
  } catch (err) {
    console.error('Update check failed:', err.message);
  } finally {
    isChecking = false;
  }
}

function initAutoUpdater(mainWindow) {
  if (!autoUpdater) {
    console.log('electron-updater not available, skipping auto-update.');
    return;
  }

  autoUpdater.autoDownload = true;
  autoUpdater.autoInstallOnAppQuit = true;
  isDownloadComplete = false;

  autoUpdater.on('update-available', (info) => {
    mainWindow.webContents.send('update:available', info.version);
  });

  autoUpdater.on('update-downloaded', (info) => {
    isDownloadComplete = true;
    mainWindow.webContents.send('update:downloaded', info.version);
  });

  autoUpdater.on('update-not-available', () => {
    mainWindow.webContents.send('update:not-available');
  });

  autoUpdater.on('error', (err) => {
    console.error('Auto-update error:', err.message);
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

module.exports = { initAutoUpdater, quitAndInstall, stopAutoUpdater };
