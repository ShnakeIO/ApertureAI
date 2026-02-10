const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

module.exports = async function afterPack(context) {
  if (context.electronPlatformName !== 'darwin') return;

  const appName = `${context.packager.appInfo.productFilename}.app`;
  const appPath = path.join(context.appOutDir, appName);
  if (!fs.existsSync(appPath)) return;
  const bundleId = context.packager.appInfo.id || context.packager.config.appId || 'com.apertureai.desktop';

  try {
    execFileSync('codesign', ['--verify', '--deep', '--strict', appPath], { stdio: 'ignore' });
    // Keep going: we still want a stable designated requirement for updates.
  } catch (err) {
    // Fall through: we'll apply our own signature below.
  }

  console.log(`[afterPack] Applying stable ad-hoc signature: ${appPath}`);
  // 1) Sign all nested code.
  execFileSync('codesign', ['--force', '--deep', '--sign', '-', appPath], { stdio: 'inherit' });
  // 2) Re-sign the top-level bundle with stable identifier requirement.
  execFileSync('codesign', [
    '--force',
    '--sign',
    '-',
    '-i',
    bundleId,
    `-r=designated => identifier "${bundleId}"`,
    appPath
  ], { stdio: 'inherit' });
  execFileSync('codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath], { stdio: 'inherit' });
  execFileSync('codesign', ['-dv', '--verbose=4', appPath], { stdio: 'inherit' });
};
