// The engine's bench row: Octane's Richards, DeltaBlue and Crypto under
// its own harness (base.js), each run for its minimum time, the score
// per suite and the geometric mean printed the way Octane prints them.
// Run by `zig build bench-js` after tools/fetch-octane.sh.
BenchmarkSuite.RunSuites({
  NotifyStart: function (name) {},
  NotifyError: function (name, error) { print(name + ': error: ' + error); },
  NotifyResult: function (name, result) { print(name + ': ' + result); },
  NotifyScore: function (score) { print('Score (version ' + BenchmarkSuite.version + '): ' + score); },
});
