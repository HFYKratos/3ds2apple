/* 3ds2apple docs — tiny progressive enhancement: pause the demo GIF.
   No analytics, no cookies, no external requests. */
(function () {
  var fig = document.querySelector('[data-gif]');
  if (!fig) return;
  var gif = fig.querySelector('.gif-anim');
  var still = fig.querySelector('.gif-still');
  var btn = fig.querySelector('.gif-toggle');
  if (!gif || !still || !btn) return;
  var pauseLabel = fig.getAttribute('data-pause-label') || 'Pause preview';
  var playLabel = fig.getAttribute('data-play-label') || 'Play preview';
  var playing = true;
  function render() {
    gif.hidden = !playing;
    still.hidden = playing;
    btn.textContent = playing ? pauseLabel : playLabel;
    btn.hidden = false;
  }
  var reduce = false;
  try { reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches; } catch (e) {}
  playing = !reduce;
  render();
  btn.addEventListener('click', function () { playing = !playing; render(); });
})();
