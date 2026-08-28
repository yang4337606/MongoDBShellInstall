const fs = require('fs');
const path = require('path');

const repoDir = path.resolve(__dirname, '..');
const files = ['generator.html', 'docs.html', 'index.html'];

for (const file of files) {
  const html = fs.readFileSync(path.join(repoDir, file), 'utf8');
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
    .map((match) => match[1]);

  scripts.forEach((script, index) => {
    try {
      new Function(script);
    } catch (error) {
      throw new Error(`${file} inline script ${index + 1}: ${error.message}`);
    }
  });

  const markupOnly = html
    .replace(/<style(?:\s[^>]*)?>[\s\S]*?<\/style>/gi, '')
    .replace(/<script(?:\s[^>]*)?>[\s\S]*?<\/script>/gi, '');
  const ids = [...markupOnly.matchAll(/\sid=["']([^"']+)["']/g)].map((match) => match[1]);
  const duplicates = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
  if (duplicates.length > 0) {
    throw new Error(`${file} duplicate IDs: ${duplicates.join(', ')}`);
  }

  console.log(`ok - ${file}: ${scripts.length} script(s), ${ids.length} unique IDs`);
}
