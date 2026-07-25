const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const sourcePath = path.join(root, "src", "index.js");
const chromeSrcDir = path.join(root, "src", "chrome");
const desktopOutputPath = path.join(root, "dist", "BetterSongify.js");
const chromeOutDir = path.join(root, "dist", "chrome");

function write(outputPath, contents) {
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  fs.writeFileSync(outputPath, contents);
  console.log(`Wrote ${path.relative(root, outputPath)}`);
}

// The base styles live in the ensureBaseStyles template literal so the
// injected desktop build stays a single file. The Chrome build also ships
// them as manifest CSS, which the page CSP cannot block.
function extractBaseCss(source) {
  const match = source.match(/style\.textContent = `([^`]*)`/);
  if (!match) throw new Error("Could not find the ensureBaseStyles CSS template literal in src/index.js");
  return match[1].trim() + "\n";
}

const source = fs.readFileSync(sourcePath, "utf8");

const banner = `// Reconstructed readable BetterSongify bundle.\n// Generated from src/index.js by tools/build.js.\n`;
write(desktopOutputPath, `${banner}${source}`);

write(path.join(chromeOutDir, "content.js"), source);
write(path.join(chromeOutDir, "background.js"), fs.readFileSync(path.join(chromeSrcDir, "background.js"), "utf8"));
write(path.join(chromeOutDir, "manifest.json"), fs.readFileSync(path.join(chromeSrcDir, "manifest.json"), "utf8"));
write(path.join(chromeOutDir, "styles.css"), extractBaseCss(source));

for (const icon of fs.readdirSync(path.join(chromeSrcDir, "icons"))) {
  write(path.join(chromeOutDir, "icons", icon), fs.readFileSync(path.join(chromeSrcDir, "icons", icon)));
}
