let PDFParse;
let mammoth;

try { PDFParse = require('pdf-parse').PDFParse; } catch (e) { PDFParse = null; }
try { mammoth = require('mammoth'); } catch (e) { mammoth = null; }

const TEXTUAL_MIMES = new Set([
  'application/json',
  'application/xml',
  'application/x-yaml',
  'application/yaml',
  'application/javascript',
  'application/x-javascript',
  'application/csv',
  'application/sql'
]);

const TEXT_EXTENSIONS = new Set([
  'txt', 'md', 'csv', 'tsv', 'json', 'xml', 'yaml', 'yml', 'log',
  'py', 'js', 'ts', 'java', 'cpp', 'h', 'swift', 'sql', 'html', 'css'
]);

function mimeTypeLooksTextual(mimeType) {
  if (!mimeType) return false;
  const lower = mimeType.toLowerCase();
  if (lower.startsWith('text/')) return true;
  return TEXTUAL_MIMES.has(lower);
}

function decodeTextBestEffort(buffer) {
  if (!buffer || buffer.length === 0) return '';
  const text = buffer.toString('utf8');
  if (!text.includes('\uFFFD')) return text;
  return buffer.toString('latin1');
}

function getExtension(fileName) {
  if (!fileName) return '';
  const dot = fileName.lastIndexOf('.');
  if (dot < 0) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

async function extractPDF(buffer) {
  if (!PDFParse) return null;
  try {
    const parser = new PDFParse({ data: new Uint8Array(buffer), verbosity: 0 });
    const result = await parser.getText();
    if (result && result.totalPages > 0) {
      let text = '';
      for (const page of result.pages) {
        if (page.text && page.text.trim().length > 0) {
          if (text.length > 0) text += '\n\n';
          text += `[Page ${page.pageNumber}]\n${page.text}`;
        }
      }
      if (text.length > 0) return text;
    }
    return null;
  } catch (err) {
    console.error('PDF extraction error:', err.message);
    return null;
  }
}

async function extractDOCX(buffer) {
  if (!mammoth) return null;
  try {
    const result = await mammoth.extractRawText({ buffer: buffer });
    if (result.value && result.value.trim().length > 0) {
      return result.value;
    }
    return null;
  } catch (err) {
    console.error('DOCX extraction error:', err.message);
    return null;
  }
}

async function extractText(buffer, mimeType, fileName) {
  const lower = (mimeType || '').toLowerCase();
  const ext = getExtension(fileName);

  // Text MIME types
  if (mimeTypeLooksTextual(lower)) {
    const text = decodeTextBestEffort(buffer);
    if (text.length > 0) return text;
  }

  // Known text extensions
  if (TEXT_EXTENSIONS.has(ext)) {
    const text = decodeTextBestEffort(buffer);
    if (text.length > 0) return text;
  }

  // PDF
  if (lower === 'application/pdf' || ext === 'pdf') {
    return await extractPDF(buffer);
  }

  // DOCX
  if (lower === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' || ext === 'docx') {
    return await extractDOCX(buffer);
  }

  // Fallback: try as text
  const fallback = decodeTextBestEffort(buffer);
  if (fallback.length > 0) return fallback;

  return null;
}

module.exports = { extractText };
