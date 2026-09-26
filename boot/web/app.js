// The fixture app: a list the page's script grows, a button that adds to
// it, and a link whose click is taken over by script.
var count = 0;
function addItem(text) {
  var li = document.createElement('li');
  li.textContent = text;
  li.className = 'item';
  document.getElementById('list').appendChild(li);
  count += 1;
  document.getElementById('count').textContent = String(count);
  return li;
}
addItem('first').classList.add('done');
addItem('second');
document.getElementById('add').addEventListener('click', function () {
  addItem('added ' + (count + 1));
});
document.getElementById('home').addEventListener('click', function (e) {
  e.preventDefault();
  document.getElementById('title').setAttribute('data-clicked', 'home');
});
window.addEventListener('load', function () {
  document.body.setAttribute('data-loaded', document.readyState);
});
// What comes after load: a timer, a frame, an interval that stops itself.
setTimeout(function () { addItem('after 30 ms'); }, 30);
requestAnimationFrame(function (t) { document.body.setAttribute('data-frame', t >= 0 ? 'yes' : 'no'); });
// The CSSOM and geometry: a style set from script, a box measured.
document.getElementById('title').style.color = 'rgb(200, 0, 0)';
var box = document.getElementById('list').getBoundingClientRect();
document.body.setAttribute('data-box', box.width > 0 && box.height > 0 ? 'yes' : 'no');
document.body.setAttribute('data-display', getComputedStyle(document.getElementById('noscript') || document.body).display);
// The network from a page: same-origin fetch and XHR through the broker.
fetch('/about.html').then(function (r) { return r.text(); }).then(function (t) {
  document.body.setAttribute('data-fetch', t.indexOf('About the fixtures') >= 0 ? 'ok' : 'bad');
});
// Another origin (the TLS fixture, a different port): allowed where the
// answer says so, refused where it does not.
fetch('https://www.moss.test:8443/cors.json').then(function (r) { return r.json(); }).then(function (j) { document.body.setAttribute('data-cors-ok', j.cors); });
fetch('https://www.moss.test:8443/about.html').catch(function () { document.body.setAttribute('data-cors', 'refused'); });
// Storage: the host keeps localStorage per origin across the pages it
// serves; sessionStorage is this document's.
var visits = Number(localStorage.getItem('visits') || '0') + 1;
localStorage.setItem('visits', String(visits));
sessionStorage.setItem('here', 'yes');
document.body.setAttribute('data-visits', String(visits) + '/' + localStorage.length + '/' + sessionStorage.getItem('here'));
var xhr = new XMLHttpRequest();
xhr.onload = function () { document.body.setAttribute('data-xhr', String(xhr.status)); };
xhr.open('GET', '/missing.html');
xhr.send();
// History and forms from script: an entry pushed and popped, a submit
// the script keeps for itself.
var pops = [];
window.addEventListener('popstate', function (e) { pops.push((e.state && e.state.n) + ':' + location.pathname); });
history.pushState({ n: 1 }, '', '/app.html?step=1');
document.body.setAttribute('data-pushed', location.search);
history.back();
document.body.setAttribute('data-popped', pops.join(',') + ':' + location.pathname);
var form = document.getElementById('form');
form.addEventListener('submit', function (e) { e.preventDefault(); document.body.setAttribute('data-submit', form.elements[0].value + '/' + form.method); });
form.requestSubmit();
// Keys and sheets.
document.addEventListener('keydown', function (e) { document.body.setAttribute('data-key', e.key + '/' + e.code); });
document.body.setAttribute('data-sheets', document.styleSheets.length + ':' + document.styleSheets[0].cssRules[1].selectorText);
var ticks = 0;
var iv = setInterval(function () {
  ticks += 1;
  document.body.setAttribute('data-ticks', String(ticks));
  if (ticks === 2) clearInterval(iv);
}, 10);
