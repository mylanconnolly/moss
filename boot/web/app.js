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
var ticks = 0;
var iv = setInterval(function () {
  ticks += 1;
  document.body.setAttribute('data-ticks', String(ticks));
  if (ticks === 2) clearInterval(iv);
}, 10);
