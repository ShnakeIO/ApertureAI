const fs = require('fs');
const path = require('path');

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function main() {
  const b64 = (process.env.APERTUREAI_GOOGLE_SERVICE_ACCOUNT_JSON_B64 || '').trim();
  if (!b64) {
    fail('Missing GitHub Secret: APERTUREAI_GOOGLE_SERVICE_ACCOUNT_JSON_B64');
  }

  let jsonText;
  try {
    jsonText = Buffer.from(b64, 'base64').toString('utf8');
  } catch (err) {
    fail('Service account secret is not valid base64.');
  }

  let parsed;
  try {
    parsed = JSON.parse(jsonText);
  } catch (err) {
    fail('Service account secret is not valid JSON.');
  }

  if (!parsed || !parsed.client_email || !parsed.private_key) {
    fail('Service account JSON missing client_email/private_key.');
  }

  const outPath = path.join('resources', 'apertureai-sa.json');
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, JSON.stringify(parsed, null, 2), 'utf8');
  const st = fs.statSync(outPath);
  console.log(`Wrote ${outPath} (${st.size} bytes) for ${parsed.client_email}`);
}

main();

