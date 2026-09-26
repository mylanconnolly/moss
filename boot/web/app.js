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
fetch('http://elsewhere.test/').catch(function () { document.body.setAttribute('data-cors', 'refused'); });
var xhr = new XMLHttpRequest();
xhr.onload = function () { document.body.setAttribute('data-xhr', String(xhr.status)); };
xhr.open('GET', '/missing.html');
xhr.send();
var ticks = 0;
var iv = setInterval(function () {
  ticks += 1;
  document.body.setAttribute('data-ticks', String(ticks));
  if (ticks === 2) clearInterval(iv);
}, 10);
