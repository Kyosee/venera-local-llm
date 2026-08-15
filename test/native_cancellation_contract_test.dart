import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native cancellation uses request generations without resetting them',
    () {
      var source = File('src/venera_local_llm.cpp').readAsStringSync();

      expect(source, contains('std::atomic<uint64_t> cancel_generation = 0;'));
      expect(source, contains('uint64_t request_generation;'));
      expect(
        source,
        contains('request_generation = engine->cancel_generation.load();'),
      );
      expect(
        source,
        contains('engine->cancel_generation.load() != request_generation'),
      );
      expect(source, contains('engine->cancel_generation.fetch_add(1);'));

      // A new request must never clear shared cancellation state and revive an
      // older generation that is still running or waiting for the engine mutex.
      expect(source, isNot(contains('cancelled.store(false)')));
    },
  );
}
