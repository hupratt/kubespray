nvm install --lts
nvm use --lts

npm install puppeteer
node -e "
const puppeteer = require('puppeteer');
(async () => {
  const b = await puppeteer.launch({ args: ['--no-sandbox'] });
  const p = await b.newPage();
  await p.setViewport({ width: 1100, height: 800 });
  await p.goto('file://' + require('path').resolve('backup-matrix.html'));
  await new Promise(r => setTimeout(r, 2000));
  await p.screenshot({ path: 'backup-matrix.png', fullPage: true });
  await b.close();
  console.log('done');
})();
"

node -e "
const puppeteer = require('puppeteer');
(async () => {
  const b = await puppeteer.launch({ args: ['--no-sandbox'] });
  const p = await b.newPage();
  await p.setViewport({ width: 1100, height: 800, deviceScaleFactor: 3 });
  await p.goto('file://' + require('path').resolve('backup-matrix.html'));
  await new Promise(r => setTimeout(r, 2000));
  await p.screenshot({ path: 'backup-matrix.png', fullPage: true });
  await b.close();
  console.log('done');
})();
"